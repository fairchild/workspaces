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
 *
 * startTurn also carries the auto-title write (#823): same durability
 * argument applies — it has to land before a tab close can lose it.
 */
import { EventEmitter } from "node:events";
import type { DatabaseHandle } from "../db/client";
import { getRepo } from "../db/repos";
import {
	appendEvents,
	getSession,
	readEvents,
	type Session,
	titleSessionIfEmpty,
	updateSession,
} from "../db/sessions";
import {
	notifyTurnCompleted,
	type TurnNotificationOutcome,
} from "../notify/turn-notification";
import { deriveSessionTitle } from "../session-title";
import { projectReplayContext } from "../transcript/replay-context";
import {
	type ComputeProvider,
	getProvider,
	type SessionResumeHandle,
	type TurnRepo,
	type TurnRequest,
} from "./provider";
import type { StreamChunk } from "./stream-chunk";

/** One in-flight turn: where its assistant message starts, when it began, and
 * the handle a user-initiated stop (#753) aborts it through. */
interface ActiveTurn {
	fromSeq: number;
	startedAt: number;
	controller: AbortController;
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

/** The calm terminal text a stopped turn's failure card shows. */
export const TURN_STOPPED_MESSAGE = "Turn stopped.";

/** Thrown inside the ingest loop when a stop aborts the turn — the existing
 * catch then records it like any other turn failure, so a stopped turn closes
 * with the same durable error + aborted-`done` pair an interrupted one does. */
class TurnStoppedError extends Error {
	constructor() {
		super(TURN_STOPPED_MESSAGE);
		this.name = "TurnStoppedError";
	}
}

/**
 * Stops the session's in-flight turn, if its ingest loop runs in THIS process:
 * aborts the loop (which closes the turn durably with `error` + aborted
 * `done`) and returns true. Returns false when no in-process turn exists —
 * the caller distinguishes "nothing to stop" from "running on another
 * instance" via resolveTurn, since this map is process-local by design.
 */
export function stopActiveTurn(sessionId: string): boolean {
	const active = activeTurns.get(sessionId);
	if (!active) return false;
	active.controller.abort();
	return true;
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
	const repo = await resolveTurnRepo(handle, session);
	const userSeq = await appendEvents(handle, session.id, [
		{ role: "user", chunk: { type: "text", content: userText } },
	]);
	// Auto-title (#823): runs on every turn, not just conditionally "the
	// first" — `titleSessionIfEmpty`'s atomic `WHERE title = ''` is what
	// actually enforces "only once", so a first message that derives no
	// usable title (blank/whitespace) correctly leaves the session open for
	// a later turn to name it, and a user-edited title is never touched
	// (its row no longer matches the empty-title guard). This sits before
	// the detached ingest starts, on the same durable path as the user
	// event itself, so a closed tab can't lose the title. Best-effort: the
	// user event above is already durably committed by this point, so a
	// title-write failure (a DB hiccup) must not fail the whole turn-start
	// and strand that committed message — it just leaves the session
	// untitled for the next turn to retry.
	try {
		await titleSessionIfEmpty(handle, session.id, deriveSessionTitle(userText));
	} catch (error) {
		console.error(`[turn-ingest] auto-title write failed for ${session.id}`, error);
	}
	const fromSeq = userSeq + 1;
	const resume = resumeHandle(session);
	const priorContext = await replayContextForTurn(
		handle,
		session.id,
		userSeq,
		resume,
	);
	const controller = new AbortController();
	const startedAt = Date.now();
	const ingest = ingestTurn(
		handle,
		session,
		userText,
		provider,
		controller.signal,
		repo,
		resume,
		priorContext,
	).then(
		(outcome) => {
			// Deregister once this turn settles — but only if a newer turn hasn't
			// already taken the slot (guards a fast resend replacing the entry).
			if (activeTurns.get(session.id)?.fromSeq === fromSeq) {
				activeTurns.delete(session.id);
			}
			// Fire after durability and active-turn cleanup; never let delivery
			// affect the turn's own promise or persisted transcript.
			try {
				void emitTurnCompletionNotification(
					handle,
					session,
					outcome,
					Date.now() - startedAt,
				);
			} catch (error) {
				console.error(
					`[turn-ingest] turn completion notification failed for ${session.id}`,
					error,
				);
			}
		},
		(error) => {
			if (activeTurns.get(session.id)?.fromSeq === fromSeq) {
				activeTurns.delete(session.id);
			}
			throw error;
		},
	);
	activeTurns.set(session.id, { fromSeq, startedAt, controller });
	return { fromSeq, ingest };
}

async function emitTurnCompletionNotification(
	handle: DatabaseHandle,
	session: Session,
	outcome: TurnNotificationOutcome,
	durationMs: number,
): Promise<void> {
	try {
		const currentSession = (await getSession(handle, session.id)) ?? session;
		const repo = currentSession.repoId
			? await getRepo(handle, currentSession.repoId)
			: undefined;
		await notifyTurnCompleted({
			session: currentSession,
			repoFullName: repo?.fullName ?? "",
			outcome,
			durationMs,
		});
	} catch (error) {
		console.error(
			`[turn-ingest] turn completion notification failed for ${session.id}`,
			error,
		);
	}
}

async function resolveTurnRepo(
	handle: DatabaseHandle,
	session: Session,
): Promise<TurnRepo | null> {
	if (!session.repoId) return null;
	const repo = await getRepo(handle, session.repoId);
	if (!repo) throw new Error(`session repo not found: ${session.repoId}`);
	return { fullName: repo.fullName, defaultBranch: repo.defaultBranch };
}

async function replayContextForTurn(
	handle: DatabaseHandle,
	sessionId: string,
	currentUserSeq: number,
	resume: SessionResumeHandle | null,
): Promise<string | null> {
	if (!resume && currentUserSeq <= 1) return null;
	try {
		const events = await readEvents(handle, sessionId);
		const priorEvents = events.filter((event) => event.seq < currentUserSeq);
		return projectReplayContext(priorEvents);
	} catch (error) {
		console.error(
			`[turn-ingest] prior context replay failed for ${sessionId}`,
			error,
		);
		return null;
	}
}

/** The abort-race verdict: the source yielded (or finished), or the stop won. */
type NextOrAborted<T> = { aborted: true } | { aborted: false; result: IteratorResult<T> };

/**
 * Races the iterator's next value against the stop signal, so a stop takes
 * effect between chunks without waiting out a slow provider step. On abort
 * the underlying generator's `return()` is fired (not awaited — its cleanup,
 * e.g. the vercel provider's sandbox teardown, proceeds in the background and
 * can only touch the sandbox, never this session's log) and any still-pending
 * `next` is defused so it can't surface as an unhandled rejection.
 */
async function nextOrAborted<T>(
	iterator: AsyncIterator<T>,
	signal: AbortSignal,
): Promise<NextOrAborted<T>> {
	if (signal.aborted) return { aborted: true };
	let onAbort: () => void = () => {};
	const aborted = new Promise<{ aborted: true }>((resolve) => {
		onAbort = () => resolve({ aborted: true });
		signal.addEventListener("abort", onAbort, { once: true });
	});
	const next = iterator
		.next()
		.then((result) => ({ aborted: false as const, result }));
	try {
		return await Promise.race([next, aborted]);
	} finally {
		signal.removeEventListener("abort", onAbort);
		if (signal.aborted) {
			next.catch(() => {});
			void iterator.return?.()?.catch?.(() => {});
		}
	}
}

/**
 * Consumes the provider turn, appending each chunk to the log and notifying
 * tail readers. Guarantees the run is closed by exactly one terminal `done`:
 * providers that emit their own `done` (the norm) close themselves; a provider
 * that ends without one, throws, or is stopped mid-turn (#753) gets a
 * synthesized terminal so the turn is never left open in the log — and a
 * failure arriving AFTER the provider's own `done` (including a stop racing
 * the turn's natural finish) appends nothing, so the log never carries a
 * second terminal. Never rejects — failures are recorded as events.
 */
async function ingestTurn(
	handle: DatabaseHandle,
	session: Session,
	userText: string,
	provider: ComputeProvider,
	signal: AbortSignal,
	repo: TurnRepo | null,
	resume: SessionResumeHandle | null,
	priorContext: string | null,
): Promise<TurnNotificationOutcome> {
	let closed = false;
	// An `error` chunk anywhere in the stream marks the turn failed for the
	// completion notice, even when the provider still closes with its own
	// `done` — the owner is being told whether the turn needs their attention,
	// not whether the stream terminated cleanly.
	let sawError = false;
	try {
		const request: TurnRequest = {
			sessionId: session.id,
			userMessage: userText,
			repo,
			resume,
			model: session.model,
			signal,
		};
		if (priorContext) request.priorContext = priorContext;
		const iterator = provider
			.runTurn(request)
			[Symbol.asyncIterator]();
		while (true) {
			const verdict = await nextOrAborted(iterator, signal);
			if (verdict.aborted) throw new TurnStoppedError();
			if (verdict.result.done) break;
			const chunk = verdict.result.value;
			// A terminal `done` may carry the harness handle the turn parked with
			// detach(); persist it to the session row (not the transcript) so the
			// next turn reconnects, and store the chunk without that private blob.
			const stored =
				chunk.type === "done"
					? await persistResume(handle, session.id, chunk)
					: chunk;
			await appendEvents(handle, session.id, [{ role: "assistant", chunk: stored }]);
			if (chunk.type === "done") closed = true;
			if (chunk.type === "error") sawError = true;
			notify(session.id);
		}
		if (!closed) {
			await appendEvents(handle, session.id, [
				{ role: "assistant", chunk: { type: "done", content: "" } },
			]);
			notify(session.id);
		}
		return sawError ? "failed" : "completed";
	} catch (error) {
		// The run already has its terminal `done` — never append a second.
		if (closed) return sawError ? "failed" : "completed";
		const message = error instanceof Error ? error.message : "the turn failed";
		await appendEvents(handle, session.id, [
			{ role: "assistant", chunk: { type: "error", content: message } },
			{ role: "assistant", chunk: { type: "done", content: "", metadata: { aborted: true } } },
		]);
		notify(session.id);
		return error instanceof TurnStoppedError ? "stopped" : "failed";
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
