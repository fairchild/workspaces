import crypto from "node:crypto";
import {
	claimSnapshotSession,
	createSession,
	getActiveSessionForThread,
	getSession as getDbSession,
	getSnapshotSessionForThread,
	updateComputeInstance,
	updateSessionStatus,
	updateSnapshotId,
} from "../agent-sessions";
import { getChatMessages, pushChatMessage } from "../chat";
import { addDiscussionComment } from "../github";
import type { AgentSession, ChatMessage } from "../types";
import { buildConversationalPrompt, resolvePersona } from "./persona-loader";
import { type ComputeProviderRegistry, getRegistry } from "./provider-registry";
import {
	type ComputeProvider,
	type ContextMessage,
	type StreamChunk,
	isSnapshotCapable,
} from "./types";

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
			// Resume existing live session
			const registry = await this.getProviderRegistry();
			const provider = registry.get(existing.computeBackend);
			if (!provider) {
				yield { type: "error", content: "Compute provider unavailable" };
				return;
			}

			// Sandbox may be gone after process restart or timeout
			let resumed = false;
			try {
				await provider.sendMessage(existing.computeInstanceId, params.message);
				resumed = true;
			} catch {
				await updateSessionStatus(existing.id, "completed");
			}

			if (resumed) {
				yield { type: "status", content: "Resuming session..." };
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

				await this.snapshotAndRelease(
					provider,
					existing.id,
					existing.computeInstanceId,
				);

				await this.persistAgentResponse(params, persona.displayName, fullText);
				return;
			}
			// Sandbox lost — fall through to snapshot restore or fresh session
		}

		// 2b. Check for snapshotted session to restore
		const snapshotted = await getSnapshotSessionForThread(
			params.repo,
			params.agentName,
			threadId,
		);

		if (snapshotted?.snapshotId) {
			// Atomic claim — only one concurrent request wins
			const claimed = await claimSnapshotSession(snapshotted.id);
			if (claimed) {
				const registry = await this.getProviderRegistry();
				const provider = registry.get(snapshotted.computeBackend);

				if (provider && isSnapshotCapable(provider)) {
					yield {
						type: "status",
						content: "Restoring previous session...",
					};

					try {
						const restored = await provider.restoreSnapshot(
							snapshotted.snapshotId,
						);
						await updateComputeInstance(snapshotted.id, restored.instanceId);

						// Build fresh context for the restored sandbox
						const { enrichedMessage, chatHistory } =
							await this.buildConversationContext(params.repo, params.message);
						await provider.sendMessage(restored.instanceId, enrichedMessage, {
							chatHistory,
							claudeSessionId: snapshotted.claudeSessionId ?? undefined,
						});

						yield { type: "status", content: "Agent is thinking..." };

						let fullText = "";
						for await (const chunk of provider.streamOutput(
							restored.instanceId,
						)) {
							if (chunk.type === "text") {
								fullText += chunk.content;
							}
							yield chunk;
						}

						await this.snapshotAndRelease(
							provider,
							snapshotted.id,
							restored.instanceId,
						);

						await this.persistAgentResponse(
							params,
							persona.displayName,
							fullText,
						);
						return;
					} catch (err) {
						console.warn(
							"[session-manager] Snapshot restore failed, creating fresh session:",
							err,
						);
						await updateSessionStatus(snapshotted.id, "completed");
					}
				} else {
					// Provider gone — release the claim
					await updateSessionStatus(snapshotted.id, "completed");
				}
			}
			// Claim lost or provider unavailable — fall through to fresh session
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
		const claudeSessionId = crypto.randomUUID();
		const session: AgentSession = {
			id: sessionId,
			repo: params.repo,
			agentName: params.agentName,
			computeBackend: provider.descriptor.id,
			computeInstanceId: null,
			snapshotId: null,
			claudeSessionId,
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

			const { chatHistory, contextMessages } =
				await this.buildConversationContext(params.repo, params.message);

			const result = await provider.createSandbox({
				sessionId,
				repo: params.repo,
				cloneUrl,
				readOnly: true,
				systemPrompt: conversationalPrompt,
				message: params.message,
				tools: "conversational",
				contextMessages,
				chatHistory,
				claudeSessionId,
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

			await this.snapshotAndRelease(provider, sessionId, result.instanceId);

			// Persist agent response
			await this.persistAgentResponse(params, persona.displayName, fullText);
		} catch (err) {
			await updateSessionStatus(sessionId, "failed");
			// Clean up any partially-created sandbox
			const instanceId = (await getDbSession(sessionId))?.computeInstanceId;
			if (instanceId) {
				await provider.destroySandbox(instanceId).catch(() => {});
			}
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

	/** Build an enriched message with recent context prepended, plus a chat history string. */
	private async buildConversationContext(
		repo: string,
		currentMessage: string,
	): Promise<{
		enrichedMessage: string;
		chatHistory: string;
		contextMessages: ContextMessage[];
	}> {
		const allMessages = await getChatMessages(repo, 100);
		const history = allMessages
			.reverse()
			.filter((m) => m.content !== currentMessage || m.authorType !== "user");

		const contextMessages: ContextMessage[] = history.slice(-10).map((m) => ({
			author: m.author,
			authorType: m.authorType,
			content: m.content,
			timestamp: m.timestamp,
		}));

		let enrichedMessage = currentMessage;
		if (contextMessages.length) {
			const contextBlock = contextMessages
				.map(
					(m) => `[${m.timestamp}] ${m.author} (${m.authorType}): ${m.content}`,
				)
				.join("\n\n");
			enrichedMessage = `## Recent conversation context\n\n${contextBlock}\n\n---\n\n## Current message\n\n${currentMessage}`;
		}

		const chatHistory = history
			.map(
				(m) => `[${m.timestamp}] ${m.author} (${m.authorType}):\n${m.content}`,
			)
			.join("\n\n===\n\n");

		return { enrichedMessage, chatHistory, contextMessages };
	}

	/**
	 * Snapshot the sandbox state for later restore, then stop it to free resources.
	 * Falls back to marking the session "active" if the provider doesn't support snapshots.
	 */
	private async snapshotAndRelease(
		provider: ComputeProvider,
		sessionId: string,
		instanceId: string,
	): Promise<void> {
		if (isSnapshotCapable(provider)) {
			try {
				const snapshotId = await provider.createSnapshot(instanceId);
				await updateSnapshotId(sessionId, snapshotId);
				await updateSessionStatus(sessionId, "snapshotted");
				return;
			} catch (err) {
				console.warn(
					"[session-manager] Snapshot failed, keeping session active:",
					err,
				);
			}
		}
		// Non-snapshot provider or snapshot failed — leave sandbox running
		await updateSessionStatus(sessionId, "active");
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
