import crypto from "node:crypto";
import {
	createSession,
	getActiveSessionForThread,
	getSession as getDbSession,
	updateComputeInstance,
	updateSessionStatus,
} from "../agent-sessions";
import { pushChatMessage } from "../chat";
import { addDiscussionComment } from "../github";
import type { AgentSession, ChatMessage } from "../types";
import { buildConversationalPrompt, resolvePersona } from "./persona-loader";
import { type ComputeProviderRegistry, getRegistry } from "./provider-registry";
import type { StreamChunk } from "./types";

export class SessionManager {
	private registry: ComputeProviderRegistry | null = null;

	private async getProviderRegistry(): Promise<ComputeProviderRegistry> {
		if (!this.registry) {
			this.registry = await getRegistry();
		}
		return this.registry;
	}

	/**
	 * Handle an @agent mention from the chat.
	 * Resolves the persona, creates or resumes a sandbox session,
	 * and yields stream chunks as the agent responds.
	 */
	async *handleMention(params: {
		repo: string;
		agentName: string;
		message: string;
		userId: string;
		githubToken: string;
		threadId?: string;
		discussionId?: string;
	}): AsyncGenerator<StreamChunk> {
		const [owner, repo] = params.repo.split("/");
		if (!owner || !repo) {
			yield { type: "error", content: "Invalid repo format" };
			return;
		}

		// 1. Resolve persona
		const persona = await resolvePersona(
			params.githubToken,
			owner,
			repo,
			params.agentName,
		);
		if (!persona) {
			yield {
				type: "error",
				content: `Agent @${params.agentName} not found in ${params.repo}`,
			};
			return;
		}

		const threadId =
			params.threadId ?? `${params.repo}:${params.agentName}:${Date.now()}`;

		// 2. Check for existing active session
		const existing = await getActiveSessionForThread(
			params.repo,
			params.agentName,
			threadId,
		);

		if (existing?.computeInstanceId) {
			// Resume existing session
			yield { type: "status", content: "Resuming session..." };
			const registry = await this.getProviderRegistry();
			const provider = registry.get(existing.computeBackend);
			if (!provider) {
				yield { type: "error", content: "Compute provider unavailable" };
				return;
			}

			await provider.sendMessage(existing.computeInstanceId, params.message);
			await updateSessionStatus(existing.id, "streaming");

			let fullText = "";
			for await (const chunk of provider.streamOutput(
				existing.computeInstanceId,
			)) {
				if (chunk.type === "text") {
					fullText += chunk.content;
				}
				yield chunk;
			}

			await updateSessionStatus(existing.id, "active");

			await this.persistAgentResponse(params, persona.displayName, fullText);
			return;
		}

		// 3. Create new session
		const registry = await this.getProviderRegistry();
		const provider = registry.getDefault();
		const availability = await provider.checkAvailability();
		if (!availability.available) {
			yield {
				type: "error",
				content: `Compute provider unavailable: ${availability.reason}`,
			};
			return;
		}

		const sessionId = crypto.randomUUID();
		const session: AgentSession = {
			id: sessionId,
			repo: params.repo,
			agentName: params.agentName,
			computeBackend: provider.descriptor.id,
			computeInstanceId: null,
			threadId,
			discussionId: params.discussionId ?? null,
			status: "starting",
			createdAt: new Date().toISOString(),
			lastActivityAt: new Date().toISOString(),
		};
		await createSession(session);

		yield { type: "status", content: "Starting agent session..." };

		try {
			const conversationalPrompt = buildConversationalPrompt(persona);
			const cloneUrl = `https://github.com/${params.repo}.git`;

			const result = await provider.createSandbox({
				sessionId,
				repo: params.repo,
				cloneUrl,
				readOnly: true,
				systemPrompt: conversationalPrompt,
				message: params.message,
				tools: "conversational",
			});

			await updateComputeInstance(sessionId, result.instanceId);
			await updateSessionStatus(sessionId, "streaming");

			yield { type: "status", content: "Agent is thinking..." };

			// Stream the response
			let fullText = "";
			for await (const chunk of provider.streamOutput(result.instanceId)) {
				if (chunk.type === "text") {
					fullText += chunk.content;
				}
				yield chunk;
			}

			await updateSessionStatus(sessionId, "active");

			// Persist agent response
			await this.persistAgentResponse(params, persona.displayName, fullText);
		} catch (err) {
			await updateSessionStatus(sessionId, "failed");
			yield {
				type: "error",
				content: `Session failed: ${err instanceof Error ? err.message : "Unknown error"}`,
			};
		}
	}

	async getSessionStatus(sessionId: string): Promise<AgentSession | null> {
		return getDbSession(sessionId);
	}

	async endSession(sessionId: string): Promise<void> {
		const session = await getDbSession(sessionId);
		if (!session?.computeInstanceId) return;

		const registry = await this.getProviderRegistry();
		const provider = registry.get(session.computeBackend);
		if (provider) {
			await provider.destroySandbox(session.computeInstanceId);
		}
		await updateSessionStatus(sessionId, "completed");
	}

	/** Persist the agent's response as a chat message and bridge to Discussion. */
	private async persistAgentResponse(
		params: {
			repo: string;
			agentName: string;
			githubToken: string;
			discussionId?: string;
		},
		displayName: string,
		responseText: string,
	): Promise<void> {
		if (!responseText) return;

		const botMessage: ChatMessage = {
			id: crypto.randomUUID(),
			repo: params.repo,
			author: displayName,
			authorType: "agent",
			content: responseText,
			agentTarget: null,
			discussionId: params.discussionId ?? null,
			discussionUrl: null,
			timestamp: new Date().toISOString(),
		};
		await pushChatMessage(botMessage);

		// Bridge to GitHub Discussion
		if (params.discussionId) {
			try {
				await addDiscussionComment(
					params.githubToken,
					params.discussionId,
					responseText,
				);
			} catch (err) {
				console.error("[session-manager] Discussion bridge error:", err);
			}
		}
	}
}

/** Lazy singleton */
let _manager: SessionManager | undefined;

export function getSessionManager(): SessionManager {
	if (!_manager) {
		_manager = new SessionManager();
	}
	return _manager;
}
