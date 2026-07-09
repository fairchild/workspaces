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
import {
	appendImmediateTurnOrQueue,
	enqueueMessage,
	type QueuedMessage,
} from "../db/queued-messages";
import type { Session } from "../db/sessions";
import type { ComputeProvider } from "./provider";
import { getProvider } from "./provider";
import {
	startNextQueuedTurn,
	startTurnFromAppendedUserEvent,
} from "./turn-ingest";
import { closeAbandonedTurn, resolveTurn, tailStream } from "./turn-tail";

export interface SessionTurn {
	kind: "started";
	/** First assistant seq — the assistant message id is `${sessionId}:${fromSeq}`. */
	fromSeq: number;
	/** The live tail of the turn, for the POST response. */
	stream: ReadableStream<UIMessageChunk>;
	/** Settles when the detached ingest has written the turn's terminal `done`;
	 * the route hands this to `after()` to keep a serverless invocation alive. */
	ingest: Promise<void>;
}

export interface QueuedSessionTurn {
	kind: "queued";
	queueId: string;
	position: number;
	queuedAt: string;
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

export type SessionTurnResult = SessionTurn | QueuedSessionTurn;

/**
 * Appends the user's message, launches the detached turn, and returns a tail
 * over its log plus the ingest promise. The provider is resolved eagerly so an
 * unknown provider rejects before anything is persisted.
 *
 * One turn at a time: a send against a session whose current turn is still
 * running (in-process, or fresh in the log per resolveTurn) is durably queued
 * instead of interleaving a second provider's chunks into the live turn's seq
 * range. The queued text does not touch session_events until an atomic
 * claim-and-append transaction dispatches it as the next turn. If the log is
 * idle but pending queue rows exist, this send also queues behind them; FIFO
 * queue order is more important than making the newest POST special.
 */
export async function runSessionTurn(
	handle: DatabaseHandle,
	session: Session,
	userText: string,
	provider: ComputeProvider = getProvider(session.provider),
): Promise<SessionTurnResult> {
	assertApprovalPolicySupported(session, provider);
	const current = await resolveTurn(handle, session.id);
	if (current.status === "running") return queueSessionTurn(handle, session, userText);
	// A stale predecessor (runner died before its `done`) is closed durably
	// before the new turn opens, so every assistant run in the log terminates.
	if (current.status === "stale" && current.fromSeq !== null) {
		await closeAbandonedTurn(handle, session.id, current.fromSeq);
	}
	const start = await appendImmediateTurnOrQueue(handle, session.id, userText);
	if (start.kind === "queued") return queuedTurnResponse(start.queued);
	const { fromSeq, ingest } = await startTurnFromAppendedUserEvent(
		handle,
		session,
		userText,
		start.userSeq,
		provider,
	);
	return { kind: "started", fromSeq, ingest, stream: tailStream(handle, session.id, fromSeq) };
}

export async function queueSessionTurn(
	handle: DatabaseHandle,
	session: Session,
	userText: string,
	provider: ComputeProvider = getProvider(session.provider),
): Promise<QueuedSessionTurn> {
	assertApprovalPolicySupported(session, provider);
	const queued = await enqueueMessage(handle, session.id, userText);
	return queuedTurnResponse(queued);
}

export async function dispatchQueuedTurnIfIdle(
	handle: DatabaseHandle,
	session: Session,
): Promise<SessionTurn | null> {
	const current = await resolveTurn(handle, session.id);
	if (current.status === "running") return null;
	if (current.status === "stale" && current.fromSeq !== null) {
		await closeAbandonedTurn(handle, session.id, current.fromSeq);
	}
	const started = await startNextQueuedTurn(handle, session.id);
	if (!started) return null;
	return {
		kind: "started",
		fromSeq: started.fromSeq,
		ingest: started.ingest,
		stream: tailStream(handle, session.id, started.fromSeq),
	};
}

function queuedTurnResponse(queued: QueuedMessage): QueuedSessionTurn {
	return {
		kind: "queued",
		queueId: queued.queueId,
		position: queued.position,
		queuedAt: queued.queuedAt,
	};
}

function assertApprovalPolicySupported(
	session: Session,
	provider: ComputeProvider,
): void {
	// Refuse, don't silently bypass: an ask-* session must never run or queue
	// against a provider that would execute tools without consulting the broker.
	if (session.approvalPolicy !== "auto" && !provider.supportsApprovals) {
		throw new ApprovalPolicyUnsupportedError(
			session.id,
			provider.id,
			session.approvalPolicy,
		);
	}
}
