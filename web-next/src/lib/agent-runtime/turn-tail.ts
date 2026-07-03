/*
 * The read side of durable turns: render a turn from the append-only log as a
 * UIMessageChunk stream, without ever running it. `tailChunks` backfills every
 * persisted assistant event of the in-flight message from its first seq, then
 * live-follows new appends (woken by the in-process bus, polled against the DB
 * as the durable fallback) until the turn's `done`. It is strictly seq-cursored
 * — each read asks for `seq > cursor` and advances the cursor — so a reconnect
 * at any point yields exactly the remainder: no gaps, no duplicates.
 *
 * `resolveTurn` answers "is there a turn to resume, and where did it start?"
 * purely from the log plus in-process liveness — no turn table needed, the log
 * is the single source of truth. An assistant run with a `done` is finished; one
 * without is running while its ingest loop lives (or its newest event is fresh),
 * and stale otherwise. A stale run is closed with a terminal `done` so it
 * projects/replays as an interrupted turn instead of hanging.
 */
import type { UIMessageChunk } from "ai";
import type { DatabaseHandle } from "../db/client";
import { appendEvents, newestEventAt, readEvents } from "../db/sessions";
import type { ProjectedEvent } from "../transcript/project-events";
import { toUIMessageChunkStream } from "../transcript/chunk-adapter";
import { folioTurnMetadata } from "../transcript/turn-stats";
import { isTurnActive, notify, subscribe } from "./turn-ingest";
import type { StreamChunk } from "./stream-chunk";

/** A turn detached before `done` whose newest event is older than this — with no
 * live in-process runner — is treated as abandoned (the runner died). */
const STALE_TURN_MS = 30_000;

/** How often a live-following tail re-queries the DB absent a bus wakeup. */
const DEFAULT_POLL_MS = 250;

export type TurnStatus = "none" | "running" | "done" | "stale";

export interface TurnState {
	status: TurnStatus;
	/** First assistant seq of the current turn (`${sessionId}:${fromSeq}` id seed). */
	fromSeq: number | null;
}

function lastSeqOf(events: readonly ProjectedEvent[], role: "user"): number {
	let seq = 0;
	for (const event of events) if (event.role === role) seq = event.seq;
	return seq;
}

/**
 * Classifies the session's current (last) turn from its log. `fromSeq` is the
 * seq the assistant message opens at — `lastUserSeq + 1` — which matches the
 * message id the projection and the live stream both derive, so all three agree.
 */
export async function resolveTurn(
	handle: DatabaseHandle,
	sessionId: string,
): Promise<TurnState> {
	const events = await readEvents(handle, sessionId);
	const lastUserSeq = lastSeqOf(events, "user");
	if (lastUserSeq === 0) return { status: "none", fromSeq: null };

	const fromSeq = lastUserSeq + 1;
	const run = events.filter(
		(event) => event.role === "assistant" && event.seq >= fromSeq,
	);
	if (run.some((event) => event.chunk.type === "done")) {
		return { status: "done", fromSeq };
	}
	if (isTurnActive(sessionId)) return { status: "running", fromSeq };

	// No live runner here: distinguish "just started elsewhere / mid-detach"
	// from "runner died" by the age of the newest event.
	const newest = await newestEventAt(handle, sessionId);
	const ageMs = newest ? Date.now() - Date.parse(newest) : Number.POSITIVE_INFINITY;
	return ageMs < STALE_TURN_MS
		? { status: "running", fromSeq }
		: { status: "stale", fromSeq };
}

/**
 * Closes an abandoned turn durably: if its assistant run has no `done`, appends
 * an error + terminal `done` so it stops resolving as active and replays as an
 * interrupted turn. Idempotent — a run that already ended is left untouched.
 */
export async function closeAbandonedTurn(
	handle: DatabaseHandle,
	sessionId: string,
	fromSeq: number,
): Promise<void> {
	const run = (await readEvents(handle, sessionId, fromSeq - 1)).filter(
		(event) => event.role === "assistant",
	);
	if (run.some((event) => event.chunk.type === "done")) return;
	await appendEvents(handle, sessionId, [
		{ role: "assistant", chunk: { type: "error", content: "Turn interrupted before completion." } },
		{ role: "assistant", chunk: { type: "done", content: "", metadata: { aborted: true } } },
	]);
	notify(sessionId);
}

/** A promise that resolves on the next append notification or after `ms`. */
function waitForAppend(sessionId: string, ms: number): Promise<void> {
	return new Promise<void>((resolve) => {
		let settled = false;
		const finish = () => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			unsubscribe();
			resolve();
		};
		const unsubscribe = subscribe(sessionId, finish);
		const timer = setTimeout(finish, ms);
	});
}

/**
 * The turn's assistant chunks, from `fromSeq` to its `done`, streamed live.
 * Backfills whatever is already persisted, then follows new appends until the
 * run closes. Seq-cursored for exactly-once delivery. If the run's ingest loop
 * vanishes without a `done` (a crash the stale path did not pre-close), a
 * terminal error + `done` is synthesized so the reader always completes.
 */
export async function* tailChunks(
	handle: DatabaseHandle,
	sessionId: string,
	fromSeq: number,
	pollMs = DEFAULT_POLL_MS,
): AsyncGenerator<StreamChunk> {
	// A cursor that only moves forward; every batch is `seq > cursor`, so no
	// event is read twice and none is skipped. A shared object lets the reader
	// advance a cursor the batch helper reads.
	const state = { cursor: fromSeq - 1 };

	while (true) {
		const { chunks, done } = await readAssistantBatch(handle, sessionId, state);
		yield* chunks;
		if (done) return;

		if (!isTurnActive(sessionId)) {
			// The runner is gone from this process. Re-read once for a `done` that
			// raced the liveness check…
			const after = await readAssistantBatch(handle, sessionId, state);
			yield* after.chunks;
			if (after.done) return;
			if (!isTurnActive(sessionId)) {
				// …still no `done`: synthesize a terminal so the reader completes
				// instead of hanging on a turn whose runner vanished.
				yield { type: "error", content: "Turn interrupted before completion." };
				yield { type: "done", content: "", metadata: { aborted: true } };
				return;
			}
		}

		await waitForAppend(sessionId, pollMs);
	}
}

/**
 * Reads the assistant events past `state.cursor` (advancing it), stopping at the
 * turn's `done`. Returns the chunks and whether that `done` was reached.
 */
async function readAssistantBatch(
	handle: DatabaseHandle,
	sessionId: string,
	state: { cursor: number },
): Promise<{ chunks: StreamChunk[]; done: boolean }> {
	const events = await readEvents(handle, sessionId, state.cursor);
	const chunks: StreamChunk[] = [];
	for (const event of events) {
		// Advance the cursor past every event read so none is re-fetched; only
		// this turn's assistant chunks are emitted. (Within a turn window every
		// event is assistant; the guard is defensive.)
		state.cursor = event.seq;
		if (event.role !== "assistant") continue;
		chunks.push(event.chunk);
		if (event.chunk.type === "done") return { chunks, done: true };
	}
	return { chunks, done: false };
}

/**
 * The tail as a UIMessageChunk ReadableStream — the exact shape both the POST
 * response and the GET reconnect route return. Message + part ids are seeded
 * from `${sessionId}:${fromSeq}` so a resumed stream, the live stream, and the
 * server-side projection all render the same message.
 */
export function tailStream(
	handle: DatabaseHandle,
	sessionId: string,
	fromSeq: number,
	pollMs = DEFAULT_POLL_MS,
): ReadableStream<UIMessageChunk> {
	const messageId = `${sessionId}:${fromSeq}`;
	let part = 0;
	return toUIMessageChunkStream(tailChunks(handle, sessionId, fromSeq, pollMs), {
		messageId,
		generateId: () => `${messageId}:p${part++}`,
		messageMetadata: folioTurnMetadata,
	});
}
