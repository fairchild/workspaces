/*
 * Auto-title failure isolation (#823, found in review): `titleSessionIfEmpty`
 * is mocked to throw, proving startTurn's try/catch keeps a title-write
 * hiccup from losing the user event that's already durably committed by the
 * time it runs, or from failing the turn-start itself.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { type DatabaseHandle, openDatabase } from "../db/client";
import { ensureRepo } from "../db/repos";
import { createSession, getSession, readEvents } from "../db/sessions";
import { notifyTurnCompleted } from "../notify/turn-notification";
import type { ComputeProvider } from "./provider";
import type { StreamChunk } from "./stream-chunk";
import { startTurn, stopActiveTurn } from "./turn-ingest";

vi.mock("../db/sessions", async (importOriginal) => {
	const actual = await importOriginal<typeof import("../db/sessions")>();
	return {
		...actual,
		titleSessionIfEmpty: vi.fn(async () => {
			throw new Error("simulated DB hiccup");
		}),
	};
});

vi.mock("../notify/turn-notification", () => ({
	notifyTurnCompleted: vi.fn(async () => {}),
}));

let open: DatabaseHandle | undefined;
let dir: string | undefined;
const notifyTurnCompletedMock = vi.mocked(notifyTurnCompleted);

function freshDb(): DatabaseHandle {
	dir = mkdtempSync(join(tmpdir(), "web-next-turn-ingest-"));
	open = openDatabase(`file:${join(dir, "test.db")}`);
	return open;
}

beforeEach(() => {
	notifyTurnCompletedMock.mockReset();
	notifyTurnCompletedMock.mockResolvedValue(undefined);
});

afterEach(async () => {
	await open?.db.destroy();
	open = undefined;
	if (dir) rmSync(dir, { recursive: true, force: true });
	dir = undefined;
	vi.unstubAllEnvs();
});

function stubProvider(chunks: StreamChunk[] = [{ type: "done", content: "" }]): ComputeProvider {
	return {
		id: "stub",
		runTurn: async function* () {
			for (const chunk of chunks) yield chunk;
		},
	};
}

function throwingProvider(error: Error): ComputeProvider {
	return {
		id: "throwing",
		runTurn: async function* () {
			throw error;
			yield { type: "done", content: "" } as StreamChunk;
		},
	};
}

function hangingProvider(): ComputeProvider {
	return {
		id: "hanging",
		runTurn: async function* () {
			await new Promise(() => {});
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

	test("threads the session repo into the provider request instead of the global fallback", async () => {
		vi.stubEnv("AGENT_TARGET_REPO", "fairchild/workspaces");
		const handle = freshDb();
		const repo = await ensureRepo(handle, "fairchild/web-next-fixtures", "trunk");
		const session = await createSession(handle, {
			id: "s-repo",
			provider: "mock",
			repoId: repo.id,
		});
		let seenRequest: unknown;
		const provider: ComputeProvider = {
			id: "stub",
			runTurn: async function* (request) {
				seenRequest = request;
				yield { type: "done", content: "" } as StreamChunk;
			},
		};

		const started = await startTurn(handle, session, "Fix the failing test", provider);
		await started.ingest;

		expect(
			(seenRequest as {
				repo?: { fullName: string; defaultBranch: string | null } | null;
			}).repo,
		).toEqual({
			fullName: "fairchild/web-next-fixtures",
			defaultBranch: "trunk",
		});
	});
});

describe("startTurn — completion notification", () => {
	test("fires with a completed payload after the terminal done is durable", async () => {
		const handle = freshDb();
		const repo = await ensureRepo(handle, "fairchild/workspaces", "main");
		const session = await createSession(handle, {
			id: "complete-session",
			provider: "mock",
			repoId: repo.id,
			title: "Fix notifications",
		});

		const started = await startTurn(handle, session, "Ship it", stubProvider());
		await started.ingest;

		const events = await readEvents(handle, "complete-session");
		expect(events.at(-1)?.chunk).toMatchObject({ type: "done" });
		await vi.waitFor(() => {
			expect(notifyTurnCompletedMock).toHaveBeenCalledWith(
				expect.objectContaining({
					durationMs: expect.any(Number),
					outcome: "completed",
					// The payload carries the repo's owner/name, resolved from the
					// repos row — sessions store only the opaque repo row id.
					repoFullName: "fairchild/workspaces",
					session: expect.objectContaining({
						id: "complete-session",
						title: "Fix notifications",
					}),
				}),
			);
		});
	});

	test("a turn that streams an error chunk but closes normally notifies failed", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "errored-session",
			provider: "mock",
		});

		const started = await startTurn(
			handle,
			session,
			"Try anyway",
			stubProvider([
				{ type: "error", content: "provider hiccup" },
				{ type: "done", content: "" },
			]),
		);
		await started.ingest;

		await vi.waitFor(() => {
			expect(notifyTurnCompletedMock).toHaveBeenCalledWith(
				expect.objectContaining({ outcome: "failed" }),
			);
		});
	});

	test("fires with a failed payload after error and aborted done are durable", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "failed-session",
			provider: "mock",
			title: "Broken turn",
		});

		const started = await startTurn(
			handle,
			session,
			"Fail",
			throwingProvider(new Error("sandbox died")),
		);
		await started.ingest;

		const events = await readEvents(handle, "failed-session");
		expect(events.slice(-2).map((event) => event.chunk)).toEqual([
			{ type: "error", content: "sandbox died" },
			{ type: "done", content: "", metadata: { aborted: true } },
		]);
		await vi.waitFor(() => {
			expect(notifyTurnCompletedMock).toHaveBeenCalledWith(
				expect.objectContaining({
					outcome: "failed",
					session: expect.objectContaining({ id: "failed-session" }),
				}),
			);
		});
	});

	test("fires with a stopped payload for the stop path", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "stopped-session",
			provider: "mock",
			title: "Stopped turn",
		});

		const started = await startTurn(handle, session, "Stop me", hangingProvider());
		expect(stopActiveTurn("stopped-session")).toBe(true);
		await started.ingest;

		const events = await readEvents(handle, "stopped-session");
		expect(events.slice(-2).map((event) => event.chunk)).toEqual([
			{ type: "error", content: "Turn stopped." },
			{ type: "done", content: "", metadata: { aborted: true } },
		]);
		await vi.waitFor(() => {
			expect(notifyTurnCompletedMock).toHaveBeenCalledWith(
				expect.objectContaining({
					outcome: "stopped",
					session: expect.objectContaining({ id: "stopped-session" }),
				}),
			);
		});
	});

	test("a synchronously throwing notifier does not reject the ingest path", async () => {
		notifyTurnCompletedMock.mockImplementationOnce(() => {
			throw new Error("notify blew up");
		});
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "notify-throws-session",
			provider: "mock",
		});

		const started = await startTurn(handle, session, "Survive", stubProvider());
		await expect(started.ingest).resolves.toBeUndefined();

		const events = await readEvents(handle, "notify-throws-session");
		expect(events.at(-1)?.chunk).toMatchObject({ type: "done" });
		await vi.waitFor(() => {
			expect(notifyTurnCompletedMock).toHaveBeenCalledOnce();
		});
	});
});
