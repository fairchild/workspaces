/*
 * Detached turn execution — the durability seam. startTurn appends the user
 * event and kicks off a client-independent ingest loop that consumes a
 * provider's StreamChunks and appends each to session_events, so a turn
 * advances and COMPLETES whether or not any browser stays connected. The
 * browser-facing routes only ever READ the log (see turn-tail.ts); closing the
 * tab cancels a reader, never the turn.
 *
 * The loop runs eagerly (fire-and-forget) so the POST response can tail it live;
 * the route additionally hands the ingest promise to next/server `after()` so a
 * serverless invocation is kept alive until the turn settles (a no-op on a
 * long-running node server). In-process state — an `activeTurns` map for
 * liveness and an EventEmitter bus for wakeups — lets same-process tail readers
 * follow without polling; the DB remains the durable source of truth, so a
 * cross-instance reader falls back to polling it.
 *
 * This is the seam #750 replaces with a sandbox-side detached runner: the
 * contract is exactly "append the turn's chunks to the log under (sessionId,
 * seq), notify, and terminate the run with a `done`".
 */
import { EventEmitter } from "node:events";
import type { DatabaseHandle } from "../db/client";
import { appendEvents, type Session, updateSession } from "../db/sessions";
import {
	type ComputeProvider,
	getProvider,
	type SessionResumeHandle,
} from "./provider";
import type { StreamChunk } from "./stream-chunk";

/** One in-flight turn: where its assistant message starts, and when it began. */
interface ActiveTurn {
	fromSeq: number;
	startedAt: number;
}

/** Turns whose ingest loop is running in THIS process, keyed by session id. */
const activeTurns = new Map<string, ActiveTurn>();

/** Wakeups for tail readers: `emit(sessionId)` after every append. */
const bus = new EventEmitter();
// One listener per concurrent tail reader; a busy session can have several.
bus.setMaxListeners(0);

/** Notifies same-process tail readers that a session's log grew. */
export function notify(sessionId: string): void {
	bus.emit(sessionId);
}

/** Subscribes to a session's append notifications; returns an unsubscribe. */
export function subscribe(sessionId: string, onAppend: () => void): () => void {
	bus.on(sessionId, onAppend);
	return () => bus.off(sessionId, onAppend);
}

/** Whether a turn's ingest loop is running in this process right now. */
export function isTurnActive(sessionId: string): boolean {
	return activeTurns.has(sessionId);
}

/** The started-at of an in-process turn, or undefined if none is running. */
export function activeTurnStartedAt(sessionId: string): number | undefined {
	return activeTurns.get(sessionId)?.startedAt;
}

export interface StartedTurn {
	/** First assistant seq — the id seed (`${sessionId}:${fromSeq}`) a tail reads from. */
	fromSeq: number;
	/** Resolves when the ingest loop has appended the turn's terminal `done`. */
	ingest: Promise<void>;
}

/**
 * Appends the user's message, then starts the detached ingest loop for the
 * assistant turn. Returns synchronously-known state (the assistant message's
 * first seq) plus the ingest promise the route hands to `after()`.
 *
 * The provider is resolved eagerly (via the default arg) so an unknown provider
 * rejects before the user event is written — nothing is persisted for a turn
 * that can never run.
 */
export async function startTurn(
	handle: DatabaseHandle,
	session: Session,
	userText: string,
	provider: ComputeProvider = getProvider(session.provider),
): Promise<StartedTurn> {
	const userSeq = await appendEvents(handle, session.id, [
		{ role: "user", chunk: { type: "text", content: userText } },
	]);
	const fromSeq = userSeq + 1;
	const ingest = ingestTurn(handle, session, userText, provider);
	activeTurns.set(session.id, { fromSeq, startedAt: Date.now() });
	// Deregister once this turn settles — but only if a newer turn hasn't
	// already taken the slot (guards a fast resend replacing the entry).
	void ingest.finally(() => {
		if (activeTurns.get(session.id)?.fromSeq === fromSeq) {
			activeTurns.delete(session.id);
		}
	});
	return { fromSeq, ingest };
}

/**
 * Consumes the provider turn, appending each chunk to the log and notifying
 * tail readers. Guarantees the run is closed by exactly one terminal `done`:
 * providers that emit their own `done` (the norm) close themselves; a provider
 * that ends without one, or throws, gets a synthesized terminal so the turn is
 * never left open in the log. Never rejects — failures are recorded as events.
 */
async function ingestTurn(
	handle: DatabaseHandle,
	session: Session,
	userText: string,
	provider: ComputeProvider,
): Promise<void> {
	let closed = false;
	try {
		for await (const chunk of provider.runTurn({
			sessionId: session.id,
			userMessage: userText,
			resume: resumeHandle(session),
		})) {
			// A terminal `done` may carry the harness handle the turn parked with
			// detach(); persist it to the session row (not the transcript) so the
			// next turn reconnects, and store the chunk without that private blob.
			const stored =
				chunk.type === "done"
					? await persistResume(handle, session.id, chunk)
					: chunk;
			await appendEvents(handle, session.id, [{ role: "assistant", chunk: stored }]);
			if (chunk.type === "done") closed = true;
			notify(session.id);
		}
		if (!closed) {
			await appendEvents(handle, session.id, [
				{ role: "assistant", chunk: { type: "done", content: "" } },
			]);
			notify(session.id);
		}
	} catch (error) {
		const message = error instanceof Error ? error.message : "the turn failed";
		await appendEvents(handle, session.id, [
			{ role: "assistant", chunk: { type: "error", content: message } },
			{ role: "assistant", chunk: { type: "done", content: "", metadata: { aborted: true } } },
		]);
		notify(session.id);
	}
}

/** The parked-session handle to resume this turn from, or null for a fresh run. */
function resumeHandle(session: Session): SessionResumeHandle | null {
	if (!session.claudeSessionId || !session.resumeState) return null;
	return {
		harnessSessionId: session.claudeSessionId,
		resumeState: session.resumeState,
	};
}

/**
 * Moves the harness resume handle a turn parked (on `done.metadata.resume`) out
 * of the transcript and onto the session row: a `SessionResumeHandle` is stored
 * for the next turn, an explicit `null` clears a stale handle (the parked
 * sandbox expired), and an absent field leaves the row untouched (mock turns).
 * Returns the chunk with the private handle stripped so the log stays clean.
 */
async function persistResume(
	handle: DatabaseHandle,
	sessionId: string,
	chunk: StreamChunk,
): Promise<StreamChunk> {
	if (!chunk.metadata || !("resume" in chunk.metadata)) return chunk;
	const { resume, ...rest } = chunk.metadata as {
		resume?: SessionResumeHandle | null;
	} & Record<string, unknown>;
	if (resume === null) {
		await updateSession(handle, sessionId, { claudeSessionId: null, resumeState: null });
	} else if (resume) {
		await updateSession(handle, sessionId, {
			claudeSessionId: resume.harnessSessionId,
			resumeState: resume.resumeState,
		});
	}
	return { ...chunk, metadata: rest };
}
