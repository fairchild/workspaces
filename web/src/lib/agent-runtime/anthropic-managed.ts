import { createHash } from "node:crypto";
import ms from "ms";
import type {
	ComputeProvider,
	ComputeProviderAvailability,
	ComputeProviderDescriptor,
	SandboxRequest,
	SandboxResult,
	StreamChunk,
} from "./types";

const API_BASE = "https://api.anthropic.com/v1";
const API_VERSION = "2023-06-01";
const BETA_HEADER = "managed-agents-2026-04-01";

// --- API response types ---

interface ManagedAgent {
	id: string;
	version: number;
}

interface ManagedEnvironment {
	id: string;
}

interface ManagedSession {
	id: string;
}

interface AgentMessageEvent {
	type: "agent.message";
	content: Array<{ type: string; text: string }>;
}

interface AgentToolUseEvent {
	type: "agent.tool_use";
	name: string;
}

// --- Helpers ---

function apiHeaders(contentType = true): Record<string, string> {
	const apiKey = process.env.ANTHROPIC_API_KEY;
	if (!apiKey) throw new Error("ANTHROPIC_API_KEY not set");
	const headers: Record<string, string> = {
		"x-api-key": apiKey,
		"anthropic-version": API_VERSION,
		"anthropic-beta": BETA_HEADER,
	};
	if (contentType) headers["content-type"] = "application/json";
	return headers;
}

function hashPrompt(prompt: string): string {
	return createHash("sha256").update(prompt).digest("hex").slice(0, 12);
}

function buildInitialMessage(request: SandboxRequest): string {
	const parts: string[] = [];

	if (request.cloneUrl) {
		const branch = request.branch ? ` -b ${request.branch}` : "";
		parts.push(
			`First, clone the repository and set up your working directory:\n\`\`\`bash\ngit clone --depth 1${branch} ${request.cloneUrl} /home/user/repo && cd /home/user/repo\n\`\`\``,
		);
	}

	if (request.contextMessages?.length) {
		const block = request.contextMessages
			.map(
				(m) => `[${m.timestamp}] ${m.author} (${m.authorType}): ${m.content}`,
			)
			.join("\n\n");
		parts.push(`## Recent conversation context\n\n${block}`);
	}

	if (request.chatHistory) {
		parts.push(
			`## Chat history\n\n<details>\n<summary>Full conversation history</summary>\n\n${request.chatHistory}\n\n</details>`,
		);
	}

	parts.push(request.message);

	return parts.join("\n\n---\n\n");
}

function mapEventToChunk(
	event: AgentMessageEvent | AgentToolUseEvent | { type: string },
): StreamChunk | null {
	switch (event.type) {
		case "agent.message": {
			const msg = event as AgentMessageEvent;
			const text = msg.content
				.filter((b) => b.type === "text")
				.map((b) => b.text)
				.join("");
			if (!text) return null;
			return { type: "text", content: text };
		}
		case "agent.tool_use": {
			const tool = event as AgentToolUseEvent;
			return {
				type: "tool_use",
				content: tool.name,
				metadata: { tool: tool.name },
			};
		}
		case "session.status_idle":
			return { type: "done", content: "" };
		default:
			return null;
	}
}

// --- Provider ---

export class AnthropicManagedProvider implements ComputeProvider {
	readonly descriptor: ComputeProviderDescriptor = {
		id: "anthropic-managed",
		displayName: "Anthropic Managed Agents",
		maxSessionDuration: ms("4h"),
		supportsSnapshot: false,
		supportsStreaming: true,
		supportsTerminal: false,
	};

	private agentCache = new Map<string, Promise<ManagedAgent>>();
	private environmentPromise: Promise<string> | undefined;

	private getOrCreateEnvironment(): Promise<string> {
		if (!this.environmentPromise) {
			this.environmentPromise = (async () => {
				const res = await fetch(`${API_BASE}/environments`, {
					method: "POST",
					headers: apiHeaders(),
					body: JSON.stringify({
						name: "workspaces-default",
						config: {
							type: "cloud",
							networking: { type: "unrestricted" },
						},
					}),
				});
				if (!res.ok) {
					this.environmentPromise = undefined;
					throw new Error(
						`Managed Agents environment creation failed: ${await res.text()}`,
					);
				}
				return ((await res.json()) as ManagedEnvironment).id;
			})();
		}
		return this.environmentPromise;
	}

	private getOrCreateAgent(systemPrompt: string): Promise<ManagedAgent> {
		const key = hashPrompt(systemPrompt);
		let promise = this.agentCache.get(key);
		if (!promise) {
			promise = (async () => {
				const res = await fetch(`${API_BASE}/agents`, {
					method: "POST",
					headers: apiHeaders(),
					body: JSON.stringify({
						name: `workspaces-${key}`,
						model: "claude-sonnet-4-6",
						system: systemPrompt,
						tools: [{ type: "agent_toolset_20260401" }],
					}),
				});
				if (!res.ok) {
					this.agentCache.delete(key);
					throw new Error(
						`Managed Agents agent creation failed: ${await res.text()}`,
					);
				}
				return (await res.json()) as ManagedAgent;
			})();
			this.agentCache.set(key, promise);
		}
		return promise;
	}

	async checkAvailability(): Promise<ComputeProviderAvailability> {
		if (!process.env.ANTHROPIC_API_KEY) {
			return { available: false, reason: "ANTHROPIC_API_KEY not configured" };
		}
		if (!process.env.ANTHROPIC_MANAGED_AGENTS) {
			return {
				available: false,
				reason: "ANTHROPIC_MANAGED_AGENTS not enabled",
			};
		}
		return { available: true };
	}

	async createSandbox(request: SandboxRequest): Promise<SandboxResult> {
		const [environmentId, agent] = await Promise.all([
			this.getOrCreateEnvironment(),
			this.getOrCreateAgent(request.systemPrompt),
		]);

		// Create session
		const sessionRes = await fetch(`${API_BASE}/sessions`, {
			method: "POST",
			headers: apiHeaders(),
			body: JSON.stringify({
				agent: agent.id,
				environment_id: environmentId,
				title: `${request.repo} — ${request.sessionId}`,
			}),
		});
		if (!sessionRes.ok) {
			throw new Error(
				`Managed Agents session creation failed: ${await sessionRes.text()}`,
			);
		}
		const session = (await sessionRes.json()) as ManagedSession;

		// Send initial message (API buffers events until stream attaches)
		const message = buildInitialMessage(request);
		const sendRes = await fetch(`${API_BASE}/sessions/${session.id}/events`, {
			method: "POST",
			headers: apiHeaders(),
			body: JSON.stringify({
				events: [
					{
						type: "user.message",
						content: [{ type: "text", text: message }],
					},
				],
			}),
		});
		if (!sendRes.ok) {
			throw new Error(
				`Managed Agents initial message failed: ${await sendRes.text()}`,
			);
		}

		return { instanceId: session.id, status: "ready" };
	}

	async *streamOutput(instanceId: string): AsyncGenerator<StreamChunk> {
		const res = await fetch(`${API_BASE}/sessions/${instanceId}/stream`, {
			headers: {
				...apiHeaders(false),
				Accept: "text/event-stream",
			},
		});

		if (!res.ok || !res.body) {
			yield { type: "error", content: `Stream failed: ${res.statusText}` };
			return;
		}

		const reader = res.body.getReader();
		const decoder = new TextDecoder();
		let buffer = "";

		while (true) {
			const { done, value } = await reader.read();
			if (done) break;

			buffer += decoder.decode(value, { stream: true });
			const lines = buffer.split("\n");
			buffer = lines.pop() ?? "";

			for (const line of lines) {
				if (!line.startsWith("data: ")) continue;
				try {
					const event = JSON.parse(line.slice(6));
					const chunk = mapEventToChunk(event);
					if (chunk) {
						yield chunk;
						if (chunk.type === "done") return;
					}
				} catch {
					// skip malformed SSE lines
				}
			}
		}

		yield { type: "done", content: "" };
	}

	async sendMessage(instanceId: string, message: string): Promise<void> {
		const res = await fetch(`${API_BASE}/sessions/${instanceId}/events`, {
			method: "POST",
			headers: apiHeaders(),
			body: JSON.stringify({
				events: [
					{
						type: "user.message",
						content: [{ type: "text", text: message }],
					},
				],
			}),
		});
		if (!res.ok) {
			throw new Error(
				`Managed Agents send message failed: ${await res.text()}`,
			);
		}
	}

	async destroySandbox(_instanceId: string): Promise<void> {
		// Sessions are managed by Anthropic and expire naturally
	}
}
