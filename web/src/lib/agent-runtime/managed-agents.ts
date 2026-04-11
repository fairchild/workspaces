import Anthropic from "@anthropic-ai/sdk";
import type {
	BetaCloudConfigParams,
	BetaLimitedNetworkParams,
} from "@anthropic-ai/sdk/resources/beta/environments";
import type { BetaManagedAgentsGitHubRepositoryResourceParams } from "@anthropic-ai/sdk/resources/beta/sessions/sessions";
import ms from "ms";
import {
	getOrCreateAgent,
	getOrCreateEnvironment,
} from "./managed-agents-cache";
import { streamWithReconnect } from "./managed-agents-events";
import type {
	ComputeProvider,
	ComputeProviderAvailability,
	ComputeProviderDescriptor,
	SandboxRequest,
	SandboxResult,
	StreamChunk,
} from "./types";

const DEFAULT_MODEL = process.env.MANAGED_AGENTS_MODEL ?? "claude-sonnet-4-5";
const ENVIRONMENT_NAME =
	process.env.MANAGED_AGENTS_ENVIRONMENT_NAME ?? "spaces-web-default";
const DESTROY_MODE =
	process.env.MANAGED_AGENTS_DESTROY_MODE === "delete" ? "delete" : "archive";

const DEFAULT_ALLOWED_HOSTS = [
	"github.com",
	"api.github.com",
	"raw.githubusercontent.com",
	"codeload.github.com",
	"objects.githubusercontent.com",
	"registry.npmjs.org",
	"pypi.org",
	"files.pythonhosted.org",
	"api.anthropic.com",
];

export class ManagedAgentsProvider implements ComputeProvider {
	readonly descriptor: ComputeProviderDescriptor = {
		id: "managed-agents",
		displayName: "Managed Agents (Anthropic)",
		maxSessionDuration: ms("24h"),
		supportsSnapshot: false,
		supportsStreaming: true,
		terminalMode: "transcript",
	};

	private _client: Anthropic | null = null;
	private availability: {
		at: number;
		result: ComputeProviderAvailability;
	} | null = null;

	private client(): Anthropic {
		if (this._client) return this._client;
		const apiKey = process.env.ANTHROPIC_API_KEY;
		if (!apiKey) {
			throw new Error("ManagedAgentsProvider: ANTHROPIC_API_KEY is not set");
		}
		this._client = new Anthropic({ apiKey });
		return this._client;
	}

	async checkAvailability(): Promise<ComputeProviderAvailability> {
		const now = Date.now();
		if (this.availability && now - this.availability.at < 60_000) {
			return this.availability.result;
		}
		const result = await this.probe();
		this.availability = { at: now, result };
		return result;
	}

	private async probe(): Promise<ComputeProviderAvailability> {
		if (!process.env.ANTHROPIC_API_KEY) {
			return { available: false, reason: "ANTHROPIC_API_KEY not set" };
		}
		try {
			// Cheap list to confirm the key works and the beta is enabled.
			const page = await this.client().beta.agents.list({ limit: 1 });
			// Consume the page to realize any lazy request errors.
			void page.data;
			return { available: true };
		} catch (err) {
			return {
				available: false,
				reason: err instanceof Error ? err.message : "agents.list failed",
			};
		}
	}

	async createSandbox(request: SandboxRequest): Promise<SandboxResult> {
		const client = this.client();
		const agentName = this.slugifyAgent(request.repo);
		const agentId = await getOrCreateAgent(client, {
			name: agentName,
			model: DEFAULT_MODEL,
			systemPrompt: request.systemPrompt,
		});
		const environmentId = await getOrCreateEnvironment(client, {
			name: ENVIRONMENT_NAME,
			config: this.buildEnvironmentConfig(),
		});

		const githubToken = request.envVars?.GITHUB_TOKEN ?? "";
		// Managed Agents requires https://github.com/{owner}/{repo} with no .git suffix
		const repoUrl = request.cloneUrl.replace(/\.git$/, "");
		const resources: BetaManagedAgentsGitHubRepositoryResourceParams[] = [
			{
				type: "github_repository",
				url: repoUrl,
				mount_path: "/workspace/repo",
				authorization_token: githubToken,
				...(request.branch
					? { checkout: { type: "branch", name: request.branch } }
					: {}),
			},
		];

		const session = await client.beta.sessions.create({
			agent: agentId,
			environment_id: environmentId,
			title: `${request.repo} — ${request.sessionId}`.slice(0, 256),
			metadata: {
				workspaceSessionId: request.sessionId,
				repo: request.repo,
			},
			resources,
		});

		await client.beta.sessions.events.send(session.id, {
			events: [
				{
					type: "user.message",
					content: [{ type: "text", text: this.buildInitialMessage(request) }],
				},
			],
		});

		return { instanceId: session.id, status: "ready" };
	}

	async *streamOutput(instanceId: string): AsyncGenerator<StreamChunk> {
		for await (const chunk of streamWithReconnect(this.client(), instanceId)) {
			yield chunk;
		}
	}

	async sendMessage(
		instanceId: string,
		message: string,
		_context?: { chatHistory?: string; claudeSessionId?: string },
	): Promise<void> {
		await this.client().beta.sessions.events.send(instanceId, {
			events: [
				{
					type: "user.message",
					content: [{ type: "text", text: message }],
				},
			],
		});
	}

	async destroySandbox(instanceId: string): Promise<void> {
		const client = this.client();
		if (DESTROY_MODE === "delete") {
			await client.beta.sessions.delete(instanceId).catch(() => {});
			return;
		}
		await client.beta.sessions.archive(instanceId).catch(() => {});
	}

	private buildInitialMessage(request: SandboxRequest): string {
		const parts: string[] = [];
		if (request.contextMessages?.length) {
			parts.push("## Recent conversation");
			for (const m of request.contextMessages) {
				parts.push(`**${m.author}** (${m.authorType}): ${m.content}`);
			}
			parts.push("");
		}
		parts.push(request.message);
		return parts.join("\n");
	}

	private buildEnvironmentConfig(): BetaCloudConfigParams {
		const networking: BetaLimitedNetworkParams = {
			type: "limited",
			allowed_hosts: DEFAULT_ALLOWED_HOSTS,
			allow_mcp_servers: true,
			allow_package_managers: true,
		};
		return {
			type: "cloud",
			networking,
		};
	}

	private slugifyAgent(repo: string): string {
		return (
			repo
				.toLowerCase()
				.replace(/[^a-z0-9-]+/g, "-")
				.replace(/^-+|-+$/g, "")
				.slice(0, 80) || "spaces-agent"
		);
	}
}
