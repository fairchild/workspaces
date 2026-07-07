/*
 * PATCH /api/sessions/[id] — auth gating, per-field validation (model,
 * title), and the "unknown field is a 400" contract. `getAuthState` is
 * mocked (it reaches into next/headers, which needs a real request scope);
 * the DB is real, pointed at a throwaway file via SESSIONS_DATABASE_URL so
 * `getDatabase()`'s module singleton (shared with the route under test)
 * resolves to it.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeEach, describe, expect, test, vi } from "vitest";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { createSession, getSession } from "@/lib/db/sessions";
import { MAX_TITLE_LENGTH } from "@/lib/session-title";

vi.mock("@/lib/auth/auth-state", () => ({
	getAuthState: vi.fn(),
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
