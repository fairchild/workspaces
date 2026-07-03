/*
 * Starts one durable agent turn against a session and returns the live view of
 * it. Execution is detached (turn-ingest.ts): the user event is appended, the
 * provider's chunks are ingested into session_events by a client-independent
 * loop, and this returns a TAIL over that log — so the returned stream is a
 * reader, not the turn itself. Closing the response cancels the reader while the
 * turn keeps running to completion; a reconnect (turn-tail.ts, the GET route)
 * resumes from the same log. Ids are seeded `${sessionId}:${fromSeq}` so the
 * live stream, a resumed stream, and a reload's projection all agree.
 */
import type { UIMessageChunk } from "ai";
import type { DatabaseHandle } from "../db/client";
import type { Session } from "../db/sessions";
import type { ComputeProvider } from "./provider";
import { getProvider } from "./provider";
import { startTurn } from "./turn-ingest";
import { tailStream } from "./turn-tail";

export interface SessionTurn {
	/** First assistant seq — the assistant message id is `${sessionId}:${fromSeq}`. */
	fromSeq: number;
	/** The live tail of the turn, for the POST response. */
	stream: ReadableStream<UIMessageChunk>;
	/** Settles when the detached ingest has written the turn's terminal `done`;
	 * the route hands this to `after()` to keep a serverless invocation alive. */
	ingest: Promise<void>;
}

/**
 * Appends the user's message, launches the detached turn, and returns a tail
 * over its log plus the ingest promise. The provider is resolved eagerly so an
 * unknown provider rejects before anything is persisted.
 */
export async function runSessionTurn(
	handle: DatabaseHandle,
	session: Session,
	userText: string,
	provider: ComputeProvider = getProvider(session.provider),
): Promise<SessionTurn> {
	const { fromSeq, ingest } = await startTurn(handle, session, userText, provider);
	return { fromSeq, ingest, stream: tailStream(handle, session.id, fromSeq) };
}
