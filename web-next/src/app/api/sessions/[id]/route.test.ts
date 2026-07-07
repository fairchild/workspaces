/*
 * /api/sessions/[id] — GET (session + durable log), PATCH (auth gating,
 * per-field validation, the "unknown field is a 400" contract), and DELETE
 * (sandbox release before cascade, a stop failure keeping the session).
 * `getAuthState` is mocked (it reaches into next/headers, which needs a real
 * request scope), as is the sandbox release (no Vercel in tests); the DB is
 * real, pointed at a throwaway file via SESSIONS_DATABASE_URL so
 * `getDatabase()`'s module singleton (shared with the route under test)
 * resolves to it.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeEach, describe, expect, test, vi } from "vitest";
import { releaseParkedSandbox } from "@/lib/agent-runtime/sandbox-release";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { appendEvents, createSession, getSession, updateSession } from "@/lib/db/sessions";
import { MAX_TITLE_LENGTH } from "@/lib/session-title";

vi.mock("@/lib/auth/auth-state", () => ({
	getAuthState: vi.fn(),
}));

vi.mock("@/lib/agent-runtime/sandbox-release", () => ({
	releaseParkedSandbox: vi.fn(),
}));

const dir = mkdtempSync(join(tmpdir(), "web-next-route-"));
process.env.SESSIONS_DATABASE_URL = `file:${join(dir, "test.db")}`;

afterAll(() => {
	rmSync(dir, { recursive: true, force: true });
});

const AUTHORIZED = {
	kind: "authorized" as const,
	user: { login: "fairchild", name: "Fairchild" },
};

beforeEach(() => {
	vi.mocked(getAuthState).mockResolvedValue(AUTHORIZED);
	vi.mocked(releaseParkedSandbox).mockResolvedValue({ disposition: "none" });
});

async function patch(id: string, body: unknown) {
	const { PATCH } = await import("./route");
	return PATCH(
		new Request(`http://test/api/sessions/${id}`, {
			method: "PATCH",
			body: JSON.stringify(body),
		}),
		{ params: Promise.resolve({ id }) },
	);
}

let seq = 0;
/** A fresh session id per test — one shared DB, no cross-test collisions. */
async function freshSession(): Promise<string> {
	const id = `s-${++seq}`;
	await createSession(getDatabase(), { id, provider: "mock" });
	return id;
}

describe("PATCH /api/sessions/[id]", () => {
	test("401s when unauthenticated", async () => {
		vi.mocked(getAuthState).mockResolvedValue({ kind: "unauthenticated" });
		const id = await freshSession();
		const res = await patch(id, { title: "New title" });
		expect(res.status).toBe(401);
	});

	test("403s when signed in but not allowlisted", async () => {
		vi.mocked(getAuthState).mockResolvedValue({ kind: "forbidden", login: "nope" });
		const id = await freshSession();
		const res = await patch(id, { title: "New title" });
		expect(res.status).toBe(403);
	});

	test("404s for an unknown session", async () => {
		const res = await patch("does-not-exist", { title: "New title" });
		expect(res.status).toBe(404);
	});

	test("rejects a field outside {model, title}", async () => {
		const id = await freshSession();
		const res = await patch(id, { title: "Fine", nickname: "nope" });
		expect(res.status).toBe(400);
		expect((await res.json()).error).toMatch(/unknown field/);
		// Nothing was written — the whole patch is rejected, not partially applied.
		expect((await getSession(getDatabase(), id))?.title).toBe("");
	});

	test("sets the title, trimmed and whitespace-collapsed", async () => {
		const id = await freshSession();
		const res = await patch(id, { title: "  Fix   the   bug  " });
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ title: "Fix the bug" });
		expect((await getSession(getDatabase(), id))?.title).toBe("Fix the bug");
	});

	test("rejects an empty (or whitespace-only) title", async () => {
		const id = await freshSession();
		const res = await patch(id, { title: "   " });
		expect(res.status).toBe(400);
		expect((await res.json()).error).toMatch(/empty/);
	});

	test("rejects a title over the length cap", async () => {
		const id = await freshSession();
		const res = await patch(id, { title: "x".repeat(MAX_TITLE_LENGTH + 1) });
		expect(res.status).toBe(400);
		expect((await res.json()).error).toMatch(/characters/);
	});

	test("rejects a non-string title", async () => {
		const id = await freshSession();
		const res = await patch(id, { title: 42 });
		expect(res.status).toBe(400);
	});

	test("rejects a title made only of zero-width characters (review finding)", async () => {
		const id = await freshSession();
		const res = await patch(id, { title: "\u200B\u200C\u200D" });
		expect(res.status).toBe(400);
		expect((await res.json()).error).toMatch(/empty/);
	});

	test("rejects an empty body — no field is a no-op patch", async () => {
		const id = await freshSession();
		const res = await patch(id, {});
		expect(res.status).toBe(400);
		expect((await res.json()).error).toMatch(/model or title is required/);
	});

	test("a title edit is never overwritten by a later auto-title write", async () => {
		const id = await freshSession();
		await patch(id, { title: "My own title" });

		// Simulate the auto-titler's write, same guarded path turn-ingest.ts uses.
		const { titleSessionIfEmpty } = await import("@/lib/db/sessions");
		const wrote = await titleSessionIfEmpty(getDatabase(), id, "Derived from a message");
		expect(wrote).toBe(false);
		expect((await getSession(getDatabase(), id))?.title).toBe("My own title");
	});

	test("still validates model (#824), unaffected by the title addition", async () => {
		const id = await freshSession();
		const res = await patch(id, { model: "not-a-real-model" });
		expect(res.status).toBe(400);
		expect((await res.json()).error).toMatch(/unknown model/);
	});

	test("accepts model and title together in one PATCH", async () => {
		const id = await freshSession();
		const res = await patch(id, { model: "claude-opus-4-8", title: "Both at once" });
		expect(res.status).toBe(200);
		const session = await getSession(getDatabase(), id);
		expect(session?.model).toBe("claude-opus-4-8");
		expect(session?.title).toBe("Both at once");
	});
});

async function get(id: string, query = "") {
	const { GET } = await import("./route");
	return GET(new Request(`http://test/api/sessions/${id}${query}`), {
		params: Promise.resolve({ id }),
	});
}

async function del(id: string) {
	const { DELETE } = await import("./route");
	return DELETE(
		new Request(`http://test/api/sessions/${id}`, { method: "DELETE" }),
		{ params: Promise.resolve({ id }) },
	);
}

describe("GET /api/sessions/[id]", () => {
	test("401s when unauthenticated, 404s for an unknown session", async () => {
		vi.mocked(getAuthState).mockResolvedValue({ kind: "unauthenticated" });
		expect((await get("whatever")).status).toBe(401);
		vi.mocked(getAuthState).mockResolvedValue(AUTHORIZED);
		expect((await get("does-not-exist")).status).toBe(404);
	});

	test("returns the session with its durable event log", async () => {
		const id = await freshSession();
		await appendEvents(getDatabase(), id, [
			{ role: "user", chunk: { type: "text", content: "hi" } },
			{ role: "assistant", chunk: { type: "status", content: "Booting Claude Code in sandbox" } },
			{ role: "assistant", chunk: { type: "done", content: "", metadata: { durationMs: 5 } } },
		]);
		const res = await get(id);
		expect(res.status).toBe(200);
		const body = await res.json();
		expect(body.session).toMatchObject({ id, provider: "mock", parked: false });
		expect(body.events).toEqual([
			{ seq: 1, role: "user", kind: "text", content: "hi" },
			{ seq: 2, role: "assistant", kind: "status", content: "Booting Claude Code in sandbox" },
			{ seq: 3, role: "assistant", kind: "done", content: "", metadata: { durationMs: 5 } },
		]);
	});

	test("parked reflects a persisted resume handle without exposing it", async () => {
		const id = await freshSession();
		await updateSession(getDatabase(), id, {
			claudeSessionId: "harness-1",
			resumeState: '{"secret":"blob"}',
		});
		const body = await (await get(id)).json();
		expect(body.session.parked).toBe(true);
		expect(JSON.stringify(body)).not.toContain("blob");
	});

	test("sinceSeq tails the log; a bad value is a 400", async () => {
		const id = await freshSession();
		await appendEvents(getDatabase(), id, [
			{ role: "user", chunk: { type: "text", content: "one" } },
			{ role: "assistant", chunk: { type: "text", content: "two" } },
		]);
		const body = await (await get(id, "?sinceSeq=1")).json();
		expect(body.events).toHaveLength(1);
		expect(body.events[0].content).toBe("two");
		expect((await get(id, "?sinceSeq=-1")).status).toBe(400);
		expect((await get(id, "?sinceSeq=nope")).status).toBe(400);
	});
});

describe("DELETE /api/sessions/[id]", () => {
	test("401s when unauthenticated, 404s for an unknown session", async () => {
		vi.mocked(getAuthState).mockResolvedValue({ kind: "unauthenticated" });
		expect((await del("whatever")).status).toBe(401);
		vi.mocked(getAuthState).mockResolvedValue(AUTHORIZED);
		expect((await del("does-not-exist")).status).toBe(404);
	});

	test("deletes the session and its log, reporting the sandbox disposition", async () => {
		const id = await freshSession();
		await appendEvents(getDatabase(), id, [
			{ role: "user", chunk: { type: "text", content: "hi" } },
		]);
		const res = await del(id);
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({ deleted: true, sandbox: "none" });
		expect(await getSession(getDatabase(), id)).toBeUndefined();
		expect((await get(id)).status).toBe(404);
	});

	test("stops a live parked sandbox before deleting", async () => {
		vi.mocked(releaseParkedSandbox).mockResolvedValue({ disposition: "stopped" });
		const id = await freshSession();
		const res = await del(id);
		expect(await res.json()).toEqual({ deleted: true, sandbox: "stopped" });
		expect(await getSession(getDatabase(), id)).toBeUndefined();
	});

	test("a sandbox that can't be stopped keeps the session for a retry (502)", async () => {
		vi.mocked(releaseParkedSandbox).mockResolvedValue({
			disposition: "stop-failed",
			detail: "api timeout",
		});
		const id = await freshSession();
		const res = await del(id);
		expect(res.status).toBe(502);
		const body = await res.json();
		expect(body.sandbox).toBe("stop-failed");
		expect(body.error).toMatch(/api timeout/);
		// The resume handle (the only pointer to the live machine) survives.
		expect(await getSession(getDatabase(), id)).toBeDefined();
	});
});
