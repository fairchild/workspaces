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
import { closeAbandonedTurn, resolveTurn, tailStream } from "./turn-tail";

export interface SessionTurn {
	/** First assistant seq — the assistant message id is `${sessionId}:${fromSeq}`. */
	fromSeq: number;
	/** The live tail of the turn, for the POST response. */
	stream: ReadableStream<UIMessageChunk>;
	/** Settles when the detached ingest has written the turn's terminal `done`;
	 * the route hands this to `after()` to keep a serverless invocation alive. */
	ingest: Promise<void>;
}

/** A send while the session's current turn is still running (route → 409). */
export class TurnConflictError extends Error {
	constructor(sessionId: string) {
		super(`a turn is already running on session ${sessionId}`);
		this.name = "TurnConflictError";
	}
}

/** A non-auto approval policy on a provider that can't enforce it (route → 409). */
export class ApprovalPolicyUnsupportedError extends Error {
	constructor(sessionId: string, provider: string, policy: string) {
		super(
			`session ${sessionId} requires approval policy "${policy}" but provider "${provider}" does not support approvals`,
		);
		this.name = "ApprovalPolicyUnsupportedError";
	}
}

/**
 * Appends the user's message, launches the detached turn, and returns a tail
 * over its log plus the ingest promise. The provider is resolved eagerly so an
 * unknown provider rejects before anything is persisted.
 *
 * One turn at a time: a send against a session whose current turn is still
 * running (in-process, or fresh in the log per resolveTurn) throws
 * TurnConflictError instead of interleaving a second provider's chunks into
 * the live turn's seq range. The client's send-gating makes this the rare
 * path, but the API is directly callable, so the log defends itself. (Two
 * truly simultaneous first sends can still race the check — full
 * serialization would need a DB reservation and is out of scope; see #811.)
 */
export async function runSessionTurn(
	handle: DatabaseHandle,
	session: Session,
	userText: string,
	provider: ComputeProvider = getProvider(session.provider),
): Promise<SessionTurn> {
	// Refuse, don't silently bypass: an ask-* session must never run on a
	// provider that would execute tools without consulting the broker.
	if (session.approvalPolicy !== "auto" && !provider.supportsApprovals) {
		throw new ApprovalPolicyUnsupportedError(
			session.id,
			provider.id,
			session.approvalPolicy,
		);
	}
	const current = await resolveTurn(handle, session.id);
	if (current.status === "running") throw new TurnConflictError(session.id);
	// A stale predecessor (runner died before its `done`) is closed durably
	// before the new turn opens, so every assistant run in the log terminates.
	if (current.status === "stale" && current.fromSeq !== null) {
		await closeAbandonedTurn(handle, session.id, current.fromSeq);
	}
	const { fromSeq, ingest } = await startTurn(handle, session, userText, provider);
	return { fromSeq, ingest, stream: tailStream(handle, session.id, fromSeq) };
}
