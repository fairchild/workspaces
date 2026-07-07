/*
 * Stopping an in-flight turn (#753): the abort must close the turn's log with
 * exactly one durable `error` + aborted-`done` pair, release the session for
 * the next send, tear the provider down, and — the race codex is pointed at —
 * never append a second terminal when the stop lands after the turn's own
 * `done` (or after a provider fault already closed it).
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { type DatabaseHandle, openDatabase } from "../db/client";
import { createSession, readEvents } from "../db/sessions";
import type { ComputeProvider } from "./provider";
import type { StreamChunk } from "./stream-chunk";
import {
	isTurnActive,
	startTurn,
	stopActiveTurn,
	TURN_STOPPED_MESSAGE,
} from "./turn-ingest";
import { resolveTurn } from "./turn-tail";

let open: DatabaseHandle | undefined;
let dir: string | undefined;

function freshDb(): DatabaseHandle {
	dir = mkdtempSync(join(tmpdir(), "web-next-turn-stop-"));
	open = openDatabase(`file:${join(dir, "test.db")}`);
	return open;
}

afterEach(async () => {
	await open?.db.destroy();
	open = undefined;
	if (dir) rmSync(dir, { recursive: true, force: true });
	dir = undefined;
});

/** A provider whose chunks the test hand-feeds, with cleanup observability. */
function controlledProvider() {
	let feed: (chunk: StreamChunk | null) => void = () => {};
	let queue: Promise<StreamChunk | null> = new Promise((resolve) => {
		feed = resolve;
	});
	const state = { cleanedUp: false };
	const provider: ComputeProvider = {
		id: "controlled",
		runTurn: async function* () {
			try {
				while (true) {
					const chunk = await queue;
					if (chunk === null) return;
					queue = new Promise((resolve) => {
						feed = resolve;
					});
					yield chunk;
				}
			} finally {
				state.cleanedUp = true;
			}
		},
	};
	return { provider, next: (chunk: StreamChunk | null) => feed(chunk), state };
}

async function until(predicate: () => boolean, ms = 2000): Promise<void> {
	const deadline = Date.now() + ms;
	while (!predicate()) {
		if (Date.now() > deadline) throw new Error("condition never held");
		await new Promise((resolve) => setTimeout(resolve, 5));
	}
}

/** Polls the log until it holds at least `count` events. */
async function untilEvents(
	handle: DatabaseHandle,
	sessionId: string,
	count: number,
): Promise<void> {
	const deadline = Date.now() + 2000;
	while ((await readEvents(handle, sessionId)).length < count) {
		if (Date.now() > deadline) throw new Error("events never appended");
		await new Promise((resolve) => setTimeout(resolve, 5));
	}
}

describe("stopActiveTurn", () => {
	test("stops a streaming turn: one error + aborted done, session released, provider torn down", async () => {
		const handle = freshDb();
		const session = await createSession(handle, { id: "s1", provider: "mock" });
		const { provider, next, state } = controlledProvider();

		const started = await startTurn(handle, session, "long job", provider);
		next({ type: "text", content: "working…" });
		// The first chunk must be durably appended before the stop, so the log
		// proves streamed work survives ahead of the stop record.
		await untilEvents(handle, "s1", 2);

		expect(stopActiveTurn("s1")).toBe(true);
		await started.ingest;

		const events = await readEvents(handle, "s1");
		const kinds = events.map((event) => event.chunk.type);
		expect(kinds).toEqual(["text", "text", "error", "done"]);
		expect(events[2].chunk.content).toBe(TURN_STOPPED_MESSAGE);
		expect(events[3].chunk.metadata?.aborted).toBe(true);

		// The turn reads as closed — a follow-up send is not a conflict.
		expect(isTurnActive("s1")).toBe(false);
		expect((await resolveTurn(handle, "s1")).status).toBe("done");

		// The provider generator's cleanup runs once its in-flight await settles
		// (the queued return() takes effect then) — and, critically, the chunk it
		// was producing never reaches the closed log above.
		next({ type: "text", content: "too late" });
		await until(() => state.cleanedUp);
		expect((await readEvents(handle, "s1")).map((e) => e.chunk.type)).toEqual([
			"text",
			"text",
			"error",
			"done",
		]);
	});

	test("returns false when nothing is running", () => {
		expect(stopActiveTurn("nope")).toBe(false);
	});

	test("a stop racing the turn's natural finish appends no second terminal", async () => {
		const handle = freshDb();
		const session = await createSession(handle, { id: "s2", provider: "mock" });
		const { provider, next } = controlledProvider();

		const started = await startTurn(handle, session, "quick job", provider);
		next({ type: "done", content: "" });
		await untilEvents(handle, "s2", 2); // the done chunk is in the log
		// Now the stop lands — after `done`, before the loop observes the
		// generator's end. It must not add a second terminal pair.
		stopActiveTurn("s2");
		await started.ingest;

		const events = await readEvents(handle, "s2");
		expect(events.map((event) => event.chunk.type)).toEqual(["text", "done"]);
	});

	test("a provider fault after its own done appends no second terminal", async () => {
		const handle = freshDb();
		const session = await createSession(handle, { id: "s3", provider: "mock" });
		const provider: ComputeProvider = {
			id: "faulty",
			runTurn: async function* () {
				yield { type: "done", content: "" } as StreamChunk;
				throw new Error("post-done fault");
			},
		};
		const started = await startTurn(handle, session, "job", provider);
		await started.ingest;
		const events = await readEvents(handle, "s3");
		expect(events.map((event) => event.chunk.type)).toEqual(["text", "done"]);
	});
});
