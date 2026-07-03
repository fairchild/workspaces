/*
 * Runs one request-scoped agent turn against a session: persists the user's
 * message to the event log, streams the provider's chunks — appending each to
 * the log as it is produced — and returns the adapted UIMessageChunk stream
 * for the response. The turn is therefore both live and durably replayable:
 * a reload mid- or post-turn projects whatever has been appended so far.
 * (Detached, client-independent execution is #749's job.)
 */
import type { UIMessageChunk } from "ai";
import type { DatabaseHandle } from "../db/client";
import { appendEvents, type Session } from "../db/sessions";
import { toUIMessageChunkStream } from "../transcript/chunk-adapter";
import { folioTurnMetadata } from "../transcript/turn-stats";
import { type ComputeProvider, getProvider } from "./provider";
import type { StreamChunk } from "./stream-chunk";

/** Yields the source's chunks, appending each to the session log first. */
async function* persistingTee(
	handle: DatabaseHandle,
	sessionId: string,
	source: AsyncIterable<StreamChunk>,
): AsyncGenerator<StreamChunk> {
	for await (const chunk of source) {
		await appendEvents(handle, sessionId, [{ role: "assistant", chunk }]);
		yield chunk;
	}
}

/**
 * Appends the user event, then returns the provider turn as a UIMessageChunk
 * stream whose message/part ids match what projectSessionEvents will derive
 * from the log (`${sessionId}:${firstSeq}` / `…:pN`) — a reload renders the
 * same message the client just streamed.
 */
export async function runSessionTurn(
	handle: DatabaseHandle,
	session: Session,
	userText: string,
	provider: ComputeProvider = getProvider(session.provider),
): Promise<ReadableStream<UIMessageChunk>> {
	const userSeq = await appendEvents(handle, session.id, [
		{ role: "user", chunk: { type: "text", content: userText } },
	]);
	const messageId = `${session.id}:${userSeq + 1}`;
	let part = 0;
	const chunks = persistingTee(
		handle,
		session.id,
		provider.runTurn({ sessionId: session.id, userMessage: userText }),
	);
	return toUIMessageChunkStream(chunks, {
		messageId,
		generateId: () => `${messageId}:p${part++}`,
		messageMetadata: folioTurnMetadata,
	});
}
