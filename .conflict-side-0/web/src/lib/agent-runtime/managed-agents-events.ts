import type Anthropic from "@anthropic-ai/sdk";
import type {
	BetaManagedAgentsAgentMessageEvent,
	BetaManagedAgentsAgentToolResultEvent,
	BetaManagedAgentsAgentToolUseEvent,
	BetaManagedAgentsSessionErrorEvent,
	BetaManagedAgentsSessionStatusIdleEvent,
	BetaManagedAgentsStreamSessionEvents,
} from "@anthropic-ai/sdk/resources/beta/sessions/events";
import type { StreamChunk } from "./types";

/**
 * Pure mapping from a Managed Agents session event to zero or more
 * `StreamChunk`s consumed by the chat UI. Keep this side-effect-free
 * so it stays trivially unit-testable.
 */
export function mapEventToChunks(
	event: BetaManagedAgentsStreamSessionEvents,
): StreamChunk[] {
	switch (event.type) {
		case "agent.message":
			return mapAgentMessage(event);
		case "agent.thinking":
			return process.env.MANAGED_AGENTS_SHOW_THINKING === "1"
				? [{ type: "status", content: "thinking" }]
				: [];
		case "agent.tool_use":
			return [mapAgentToolUse(event)];
		case "agent.tool_result":
			return mapAgentToolResult(event);
		case "session.status_idle":
			return isEndOfTurn(event) ? [{ type: "done", content: "" }] : [];
		case "session.error":
			return [mapSessionError(event)];
		default:
			return [];
	}
}

function mapAgentMessage(
	event: BetaManagedAgentsAgentMessageEvent,
): StreamChunk[] {
	const chunks: StreamChunk[] = [];
	for (const block of event.content ?? []) {
		if (block?.type === "text" && typeof block.text === "string") {
			chunks.push({ type: "text", content: block.text });
		}
	}
	return chunks;
}

function mapAgentToolUse(
	event: BetaManagedAgentsAgentToolUseEvent,
): StreamChunk {
	return {
		type: "tool_use",
		content: event.name,
		metadata: { id: event.id, input: event.input },
	};
}

function mapAgentToolResult(
	event: BetaManagedAgentsAgentToolResultEvent,
): StreamChunk[] {
	const textParts: string[] = [];
	for (const block of event.content ?? []) {
		if (block && (block as { type?: string }).type === "text") {
			textParts.push((block as { text?: string }).text ?? "");
		}
	}
	const text = textParts.join("");
	if (!text) return [];
	return [
		{
			type: "tool_result",
			content: text,
			metadata: { tool_use_id: event.tool_use_id },
		},
	];
}

function mapSessionError(
	event: BetaManagedAgentsSessionErrorEvent,
): StreamChunk {
	const err = event.error as { message?: string; type?: string } | undefined;
	const message = err?.message ?? err?.type ?? "session.error";
	return { type: "error", content: message };
}

/**
 * Returns true when the idle event signals the agent is done with this turn
 * (or gave up). `requires_action` means the agent is blocked on client input;
 * we surface that as "not end of turn" — the caller decides what to do.
 */
export function isEndOfTurn(
	event: BetaManagedAgentsSessionStatusIdleEvent,
): boolean {
	const reason = event.stop_reason?.type;
	return reason === "end_turn" || reason === "retries_exhausted";
}

/**
 * Stream session events with best-effort reconnection. On disconnect before
 * end-of-turn, list the session history, replay any events we haven't seen
 * yet, then re-open the live stream. Bounded by `maxReconnects`.
 */
export async function* streamWithReconnect(
	client: Anthropic,
	sessionId: string,
	options: { maxReconnects?: number } = {},
): AsyncGenerator<StreamChunk> {
	const maxReconnects = options.maxReconnects ?? 3;
	const seen = new Set<string>();
	let attempts = 0;

	while (true) {
		let endedNaturally = false;
		try {
			const stream = await client.beta.sessions.events.stream(sessionId);
			try {
				for await (const event of stream) {
					if (event.id && seen.has(event.id)) continue;
					if (event.id) seen.add(event.id);
					for (const chunk of mapEventToChunks(event)) {
						yield chunk;
						if (chunk.type === "done" || chunk.type === "error") {
							endedNaturally = true;
							return;
						}
					}
				}
				endedNaturally = true;
			} finally {
				(
					stream as unknown as { controller?: { abort?: () => void } }
				).controller?.abort?.();
			}
		} catch (err) {
			if (attempts >= maxReconnects) {
				yield {
					type: "error",
					content: `stream failed after ${attempts} reconnects: ${
						err instanceof Error ? err.message : String(err)
					}`,
				};
				return;
			}
		}

		if (endedNaturally) return;
		attempts += 1;

		// Backfill anything we missed between the drop and the retry.
		try {
			for await (const event of client.beta.sessions.events.list(sessionId, {
				order: "asc",
			})) {
				if (event.id && seen.has(event.id)) continue;
				if (event.id) seen.add(event.id);
				for (const chunk of mapEventToChunks(
					event as BetaManagedAgentsStreamSessionEvents,
				)) {
					yield chunk;
					if (chunk.type === "done" || chunk.type === "error") return;
				}
			}
		} catch (err) {
			yield {
				type: "error",
				content: `events.list failed during reconnect: ${
					err instanceof Error ? err.message : String(err)
				}`,
			};
			return;
		}
	}
}
