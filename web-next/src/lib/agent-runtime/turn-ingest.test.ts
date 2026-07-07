/*
 * Auto-title failure isolation (#823, found in review): `titleSessionIfEmpty`
 * is mocked to throw, proving startTurn's try/catch keeps a title-write
 * hiccup from losing the user event that's already durably committed by the
 * time it runs, or from failing the turn-start itself.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";
import { type DatabaseHandle, openDatabase } from "../db/client";
import { createSession, getSession, readEvents } from "../db/sessions";
import type { ComputeProvider } from "./provider";
import type { StreamChunk } from "./stream-chunk";
import { startTurn } from "./turn-ingest";

vi.mock("../db/sessions", async (importOriginal) => {
	const actual = await importOriginal<typeof import("../db/sessions")>();
	return {
		...actual,
		titleSessionIfEmpty: vi.fn(async () => {
			throw new Error("simulated DB hiccup");
		}),
	};
});

let open: DatabaseHandle | undefined;
let dir: string | undefined;

function freshDb(): DatabaseHandle {
	dir = mkdtempSync(join(tmpdir(), "web-next-turn-ingest-"));
	open = openDatabase(`file:${join(dir, "test.db")}`);
	return open;
}

afterEach(async () => {
	await open?.db.destroy();
	open = undefined;
	if (dir) rmSync(dir, { recursive: true, force: true });
	dir = undefined;
});

function stubProvider(): ComputeProvider {
	return {
		id: "stub",
		runTurn: async function* () {
			yield { type: "done", content: "" } as StreamChunk;
		},
	};
}

describe("startTurn — auto-title failure isolation", () => {
	test("a title-write failure doesn't lose the already-durable user event or fail turn-start", async () => {
		const handle = freshDb();
		const session = await createSession(handle, { id: "s1", provider: "mock" });

		const started = await startTurn(handle, session, "Fix the login bug", stubProvider());
		expect(started.fromSeq).toBe(2);
		await started.ingest;

		const events = await readEvents(handle, "s1");
		expect(events[0]).toMatchObject({
			role: "user",
			chunk: { type: "text", content: "Fix the login bug" },
		});
		// The (mocked) title write failed — the session stays untitled, but
		// nothing else about the turn was lost or blocked.
		expect((await getSession(handle, "s1"))?.title).toBe("");
	});
});
