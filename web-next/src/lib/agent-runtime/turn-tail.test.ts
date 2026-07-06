/*
 * The durable-resume contract: turn-state classification, and the tail's
 * exactly-once seq cursor across the backfill→live boundary (the property that
 * makes a reconnect lossless and duplicate-free).
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readUIMessageStream, type UIMessage } from "ai";
import { afterEach, describe, expect, test } from "vitest";
import { type DatabaseHandle, openDatabase } from "../db/client";
import {
	type AppendEvent,
	appendEvents,
	createSession,
	readTranscript,
} from "../db/sessions";
import type { ComputeProvider } from "./provider";
import type { StreamChunk } from "./stream-chunk";
import { startTurn } from "./turn-ingest";
import {
	closeAbandonedTurn,
	resolveTurn,
	tailChunks,
	tailStream,
} from "./turn-tail";

let open: DatabaseHandle | undefined;
let dir: string | undefined;

function freshDb(): DatabaseHandle {
	dir = mkdtempSync(join(tmpdir(), "web-next-tail-"));
	open = openDatabase(`file:${join(dir, "test.db")}`);
	return open;
}

afterEach(async () => {
	await open?.db.destroy();
	open = undefined;
	if (dir) rmSync(dir, { recursive: true, force: true });
	dir = undefined;
});

const tick = () => new Promise((r) => setTimeout(r, 25));

function text(content: string): StreamChunk {
	return { type: "text", content };
}
function evt(role: AppendEvent["role"], chunk: StreamChunk): AppendEvent {
	return { role, chunk };
}

/** A provider whose chunks are fed in by the test, so ingest can be paced. */
function manualProvider(): {
	provider: ComputeProvider;
	push: (chunk: StreamChunk) => void;
	end: () => void;
} {
	const queue: StreamChunk[] = [];
	let wake: (() => void) | null = null;
	let ended = false;
	async function* gen(): AsyncGenerator<StreamChunk> {
		while (true) {
			const next = queue.shift();
			if (next) {
				yield next;
				continue;
			}
			if (ended) return;
			await new Promise<void>((resolve) => {
				wake = resolve;
			});
		}
	}
	return {
		provider: { id: "manual", runTurn: () => gen() },
		push(chunk) {
			queue.push(chunk);
			wake?.();
			wake = null;
		},
		end() {
			ended = true;
			wake?.();
			wake = null;
		},
	};
}

async function collect(gen: AsyncGenerator<StreamChunk>): Promise<StreamChunk[]> {
	const out: StreamChunk[] = [];
	for await (const chunk of gen) out.push(chunk);
	return out;
}

describe("resolveTurn", () => {
	test("no user message → none", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s", provider: "mock" });
		expect(await resolveTurn(handle, "s")).toEqual({ status: "none", fromSeq: null });
	});

	test("a completed assistant run → done, opening at lastUserSeq + 1", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s", provider: "mock" });
		await appendEvents(handle, "s", [
			evt("user", text("hi")),
			evt("assistant", text("hello")),
			evt("assistant", { type: "done", content: "" }),
		]);
		expect(await resolveTurn(handle, "s")).toEqual({ status: "done", fromSeq: 2 });
	});

	test("an in-process turn with no done yet → running", async () => {
		const handle = freshDb();
		const session = await createSession(handle, { id: "s", provider: "mock" });
		const { provider, push, end } = manualProvider();
		const { ingest } = await startTurn(handle, session, "go", provider);
		push(text("working "));
		await tick();
		expect(await resolveTurn(handle, "s")).toMatchObject({ status: "running", fromSeq: 2 });
		end();
		await ingest;
	});

	test("an unfinished run with no live runner and an old event → stale", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s", provider: "mock" });
		await appendEvents(handle, "s", [evt("user", text("hi"))]);
		// Backdate the assistant prefix so the liveness clock reads it as stale.
		const old = new Date(Date.now() - 60_000).toISOString();
		await handle.client.execute({
			sql: `INSERT INTO session_events (session_id, seq, role, kind, payload, created_at)
				VALUES ('s', 2, 'assistant', 'text', ?, ?)`,
			args: [JSON.stringify(text("half a ")), old],
		});
		expect(await resolveTurn(handle, "s")).toEqual({ status: "stale", fromSeq: 2 });
	});
});

describe("tailChunks — exactly-once seq cursor", () => {
	test("backfills a completed turn in order, once, ending at done", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s", provider: "mock" });
		const run: AppendEvent[] = [
			evt("user", text("fix it")),
			evt("assistant", text("On it. ")),
			evt("assistant", {
				type: "tool_use",
				content: "Read",
				metadata: { toolUseId: "t1", toolName: "Read", input: { file_path: "a.ts" } },
			}),
			evt("assistant", { type: "tool_result", content: "body", metadata: { toolUseId: "t1" } }),
			evt("assistant", { type: "done", content: "", metadata: { durationMs: 3 } }),
		];
		await appendEvents(handle, "s", run);

		const chunks = await collect(tailChunks(handle, "s", 2));
		expect(chunks.map((c) => c.type)).toEqual(["text", "tool_use", "tool_result", "done"]);
	});

	test("no gaps or duplicates across the backfill→live boundary", async () => {
		const handle = freshDb();
		const session = await createSession(handle, { id: "s", provider: "mock" });
		const { provider, push, end } = manualProvider();
		const { fromSeq, ingest } = await startTurn(handle, session, "go", provider);

		// A persisted prefix (backfill window).
		push(text("A "));
		push(text("B "));
		await tick();

		// Start tailing, THEN append more (live window) — overlapping windows.
		const collected: StreamChunk[] = [];
		const tailed = (async () => {
			for await (const chunk of tailChunks(handle, "s", fromSeq, 20)) {
				collected.push(chunk);
			}
		})();
		await tick();
		push({
			type: "tool_use",
			content: "Edit",
			metadata: { toolUseId: "t1", toolName: "Edit", input: { file_path: "a.ts" } },
		});
		push({ type: "tool_result", content: "ok", metadata: { toolUseId: "t1" } });
		await tick();
		push({ type: "done", content: "" });
		end();

		await ingest;
		await tailed;

		// Every event exactly once, in seq order: prefix then remainder, no repeat.
		expect(collected.map((c) => [c.type, c.content])).toEqual([
			["text", "A "],
			["text", "B "],
			["tool_use", "Edit"],
			["tool_result", "ok"],
			["done", ""],
		]);
	});

	test("a resumed tail reduces to the same message the log projects", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s", provider: "mock" });
		await appendEvents(handle, "s", [
			evt("user", text("fix it")),
			evt("assistant", text("Looking. ")),
			evt("assistant", {
				type: "tool_use",
				content: "Read",
				metadata: { toolUseId: "t1", toolName: "Read", input: { file_path: "a.ts" } },
			}),
			evt("assistant", { type: "tool_result", content: "body", metadata: { toolUseId: "t1" } }),
			evt("assistant", { type: "text", content: "Done." }),
			evt("assistant", { type: "done", content: "", metadata: { durationMs: 9 } }),
		]);

		let resumed: UIMessage | undefined;
		for await (const message of readUIMessageStream({
			stream: tailStream(handle, "s", 2),
		})) {
			resumed = message;
		}
		const projected = (await readTranscript(handle, "s")).find((m) => m.role === "assistant");
		expect(resumed).toEqual(projected);
	});
});

describe("closeAbandonedTurn", () => {
	test("closes an open run with a terminal done, then is a no-op", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s", provider: "mock" });
		await appendEvents(handle, "s", [
			evt("user", text("hi")),
			evt("assistant", text("partial ")),
		]);

		await closeAbandonedTurn(handle, "s", 2);
		expect(await resolveTurn(handle, "s")).toEqual({ status: "done", fromSeq: 2 });

		// Idempotent: an already-closed run gains no further events.
		const before = (await readTranscript(handle, "s")).length;
		await closeAbandonedTurn(handle, "s", 2);
		expect((await readTranscript(handle, "s")).length).toBe(before);
	});
});

describe("tailChunks — cross-instance liveness (#810)", () => {
	test("a runnerless tail follows a fresh log to its real done, never synthesizing", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s", provider: "mock" });
		// The turn "runs" in another instance: events land in the log with fresh
		// timestamps, but this process's activeTurns map has never seen it.
		await appendEvents(handle, "s", [
			evt("user", text("go")),
			evt("assistant", text("cross ")),
		]);

		const collected: StreamChunk[] = [];
		const tailed = (async () => {
			for await (const chunk of tailChunks(handle, "s", 2, 15)) {
				collected.push(chunk);
			}
		})();

		// Give the tail several poll cycles: it must keep following the fresh
		// log, not declare the turn interrupted.
		await new Promise((r) => setTimeout(r, 90));
		expect(collected.map((c) => c.type)).toEqual(["text"]);

		// The "other instance" finishes the turn; the tail catches up and ends
		// on the real terminal.
		await appendEvents(handle, "s", [
			evt("assistant", text("done ")),
			evt("assistant", { type: "done", content: "" }),
		]);
		await tailed;
		expect(collected.map((c) => c.type)).toEqual(["text", "text", "done"]);
		expect(collected.some((c) => c.type === "error")).toBe(false);
		expect(collected.at(-1)?.metadata?.aborted).toBeUndefined();
	});

	test("a runnerless tail synthesizes a terminal once the log is stale", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s", provider: "mock" });
		await appendEvents(handle, "s", [
			evt("user", text("go")),
			evt("assistant", text("half ")),
		]);
		// Backdate the whole log past the stale threshold: the runner is gone
		// and nothing is appending anymore.
		const old = new Date(Date.now() - 60_000).toISOString();
		await handle.client.execute({
			sql: "UPDATE session_events SET created_at = ? WHERE session_id = 's'",
			args: [old],
		});

		const chunks = await collect(tailChunks(handle, "s", 2, 10));
		expect(chunks.map((c) => c.type)).toEqual(["text", "error", "done"]);
		expect(chunks.at(-1)?.metadata?.aborted).toBe(true);
	});
});
