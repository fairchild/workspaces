import ms from "ms";
import type {
	ComputeProvider,
	ComputeProviderAvailability,
	ComputeProviderDescriptor,
	SandboxRequest,
	SandboxResult,
	SnapshotCapable,
	StreamChunk,
} from "./types";

/**
 * Cloudflare Sandbox provider.
 *
 * Delegates sandbox lifecycle to a Cloudflare Worker (TerminalShare proxy)
 * that uses the Cloudflare Sandbox SDK internally. This provider calls
 * the Worker's HTTP API from our Next.js backend.
 *
 * Terminal access is native — the Worker exposes `sandbox.terminal(request)`
 * via a WebSocket endpoint, giving full PTY support without ttyd.
 */
export class CloudflareSandboxProvider
	implements ComputeProvider, SnapshotCapable
{
	readonly descriptor: ComputeProviderDescriptor = {
		id: "cloudflare-sandbox",
		displayName: "Cloudflare Sandbox",
		maxSessionDuration: ms("5h"),
		supportsSnapshot: true,
		supportsStreaming: true,
	};

	private get baseUrl(): string {
		return (
			process.env.CLOUDFLARE_SANDBOX_WORKER_URL ?? "https://terminalshare.com"
		);
	}

	private get secret(): string {
		return process.env.CLOUDFLARE_SANDBOX_SECRET ?? "";
	}

	async checkAvailability(): Promise<ComputeProviderAvailability> {
		if (!process.env.CLOUDFLARE_SANDBOX_WORKER_URL) {
			return {
				available: false,
				reason: "CLOUDFLARE_SANDBOX_WORKER_URL not configured",
			};
		}
		if (!process.env.CLOUDFLARE_SANDBOX_SECRET) {
			return {
				available: false,
				reason: "CLOUDFLARE_SANDBOX_SECRET not configured",
			};
		}

		try {
			const res = await fetch(`${this.baseUrl}/health`);
			return { available: res.ok };
		} catch {
			return { available: false, reason: "Worker unreachable" };
		}
	}

	async createSandbox(request: SandboxRequest): Promise<SandboxResult> {
		const res = await fetch(`${this.baseUrl}/sandbox/create`, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				Authorization: `Bearer ${this.secret}`,
			},
			body: JSON.stringify({
				sessionId: request.sessionId,
				repo: request.repo,
				cloneUrl: request.cloneUrl,
				branch: request.branch,
				readOnly: request.readOnly,
				systemPrompt: request.systemPrompt,
				message: request.message,
				tools: request.tools,
				envVars: request.envVars,
				contextMessages: request.contextMessages,
				chatHistory: request.chatHistory,
				claudeSessionId: request.claudeSessionId,
			}),
		});

		if (!res.ok) {
			const body = await res.text();
			throw new Error(`Cloudflare sandbox creation failed: ${body}`);
		}

		return (await res.json()) as SandboxResult;
	}

	async *streamOutput(instanceId: string): AsyncGenerator<StreamChunk> {
		const res = await fetch(`${this.baseUrl}/sandbox/${instanceId}/stream`, {
			headers: { Authorization: `Bearer ${this.secret}` },
		});

		if (!res.ok || !res.body) {
			yield {
				type: "error",
				content: `Stream failed: ${res.statusText}`,
			};
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
					yield JSON.parse(line.slice(6)) as StreamChunk;
				} catch {
					// skip malformed SSE
				}
			}
		}

		yield { type: "done", content: "" };
	}

	async sendMessage(
		instanceId: string,
		message: string,
		context?: { chatHistory?: string; claudeSessionId?: string },
	): Promise<void> {
		const res = await fetch(`${this.baseUrl}/sandbox/${instanceId}/message`, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				Authorization: `Bearer ${this.secret}`,
			},
			body: JSON.stringify({ message, ...context }),
		});
		if (!res.ok) {
			throw new Error(`Send message failed: ${await res.text()}`);
		}
	}

	async destroySandbox(instanceId: string): Promise<void> {
		await fetch(`${this.baseUrl}/sandbox/${instanceId}`, {
			method: "DELETE",
			headers: { Authorization: `Bearer ${this.secret}` },
		});
	}

	async createSnapshot(instanceId: string): Promise<string> {
		const res = await fetch(`${this.baseUrl}/sandbox/${instanceId}/snapshot`, {
			method: "POST",
			headers: { Authorization: `Bearer ${this.secret}` },
		});
		if (!res.ok) {
			throw new Error(`Snapshot failed: ${await res.text()}`);
		}
		const data = (await res.json()) as { snapshotId: string };
		return data.snapshotId;
	}

	async restoreSnapshot(snapshotId: string): Promise<SandboxResult> {
		const res = await fetch(`${this.baseUrl}/sandbox/restore`, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				Authorization: `Bearer ${this.secret}`,
			},
			body: JSON.stringify({ snapshotId }),
		});
		if (!res.ok) {
			throw new Error(`Restore failed: ${await res.text()}`);
		}
		return (await res.json()) as SandboxResult;
	}
}

/**
 * Liveness + terminal URL for a Cloudflare sandbox session.
 *
 * TODO: once the @cloudflare/sandbox SDK is wired into the TerminalShare
 * Worker, this should make an HTTP call to the Worker to check if the
 * sandbox is actually alive. Today the sandbox lifecycle routes return
 * 501, so we can only report based on Worker configuration.
 */
export type SandboxState =
	| { alive: false }
	| { alive: true; terminalUrl?: string };

export async function resolveSandboxState(
	instanceId: string,
): Promise<SandboxState> {
	const workerUrl = process.env.CLOUDFLARE_SANDBOX_WORKER_URL;
	if (!workerUrl) return { alive: false };
	const wsUrl = workerUrl.replace(/^https?:\/\//, "wss://");
	return { alive: true, terminalUrl: `${wsUrl}/ws/${instanceId}` };
}
