/*
 * Pure projection: an append-only session_events log → the UIMessage[] a
 * transcript renders. This is the read side of the durable-turns architecture
 * (the log is the single source of truth; messages are never stored).
 *
 * It COMPOSES the existing StreamChunk→UIMessageChunk adapter (chunk-adapter.ts)
 * with the AI SDK's `readUIMessageStream` reducer, so tool-call pairing and text
 * bracketing live in exactly one place: stored events replay through the same
 * adapter that live streams use, then reduce to messages identically. Same log
 * in → same UIMessage[] out (ids are derived from session id + seq, never
 * randomised), which is what lets #749 resume a transcript from the DB alone.
 */
import { type UIMessage, readUIMessageStream } from "ai";
import type { StreamChunk } from "../agent-runtime/stream-chunk";
import { toUIMessageChunkStream } from "./chunk-adapter";
import { folioTurnMetadata } from "./turn-stats";

export type SessionEventRole = "user" | "assistant";

/** One stored event: a provider StreamChunk tagged with its turn role and seq. */
export interface ProjectedEvent {
	/** Per-session monotonic position; also the id seed for the message it opens. */
	seq: number;
	role: SessionEventRole;
	chunk: StreamChunk;
}

/**
 * Projects a session's event log into its full transcript (user + assistant
 * UIMessages). Deterministic: events are ordered by `seq`, grouped into
 * messages, and given stable ids of the form `${sessionId}:${firstSeq}`.
 *
 * Grouping rules:
 * - A run of consecutive `user` events becomes one user message (their text
 *   concatenated) — a turn starts with the user's message.
 * - A run of consecutive `assistant` events becomes one assistant message,
 *   split whenever a `done` chunk closes a turn, so several assistant turns in
 *   one log each project to their own message.
 * - Assistant runs replay through the adapter + `readUIMessageStream`; transient
 *   `status` chunks and stream `error`s never break projection (they are
 *   dropped / surfaced out-of-band, matching the adapter contract).
 * - An assistant run that yields no renderable parts (e.g. only status/error) is
 *   omitted rather than emitting an empty bubble.
 */
export async function projectSessionEvents(
	sessionId: string,
	events: readonly ProjectedEvent[],
): Promise<UIMessage[]> {
	const ordered = [...events].sort((a, b) => a.seq - b.seq);
	const messages: UIMessage[] = [];

	let i = 0;
	while (i < ordered.length) {
		const { role, seq: firstSeq } = ordered[i];
		if (role === "user") {
			const chunks: StreamChunk[] = [];
			while (i < ordered.length && ordered[i].role === "user") {
				chunks.push(ordered[i].chunk);
				i += 1;
			}
			messages.push(buildUserMessage(messageId(sessionId, firstSeq), chunks));
		} else {
			const chunks: StreamChunk[] = [];
			while (i < ordered.length && ordered[i].role === "assistant") {
				const chunk = ordered[i].chunk;
				chunks.push(chunk);
				i += 1;
				if (chunk.type === "done") break; // this assistant turn ends here
			}
			const message = await buildAssistantMessage(
				messageId(sessionId, firstSeq),
				chunks,
			);
			if (message) messages.push(message);
		}
	}

	return messages;
}

function messageId(sessionId: string, firstSeq: number): string {
	return `${sessionId}:${firstSeq}`;
}

/** A user message is plain text — the concatenated content of its events. */
function buildUserMessage(id: string, chunks: StreamChunk[]): UIMessage {
	const text = chunks.map((chunk) => chunk.content).join("");
	return { id, role: "user", parts: [{ type: "text", text, state: "done" }] };
}

/**
 * Replays assistant events through the shared adapter and reduces the resulting
 * UIMessageChunk stream to a single message. Part ids are seeded from the
 * message id so the projection is byte-for-byte reproducible. Metadata (author
 * + turn stats) is derived by the same folioTurnMetadata the live stream uses,
 * so a completed turn projects with its receipt and an unfinished one without.
 */
async function buildAssistantMessage(
	id: string,
	chunks: StreamChunk[],
): Promise<UIMessage | undefined> {
	let part = 0;
	const stream = toUIMessageChunkStream(chunks, {
		messageId: id,
		generateId: () => `${id}:p${part++}`,
		messageMetadata: folioTurnMetadata,
	});
	let last: UIMessage | undefined;
	// readUIMessageStream yields the growing message on each update; the final
	// value is the complete one. onError swallows stream `error` chunks so a
	// failed turn still projects whatever it produced before failing.
	for await (const message of readUIMessageStream({ stream, onError: () => {} })) {
		last = message;
	}
	if (!last || last.parts.length === 0) return undefined;
	return last;
}
