/*
 * POST /api/sessions — auth gating, field validation, and the created row's
 * defaults (DEFAULT_MODEL, empty repo). Same harness pattern as the [id]
 * route's tests: mocked auth state, real DB behind SESSIONS_DATABASE_URL.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeEach, describe, expect, test, vi } from "vitest";
import { DEFAULT_MODEL } from "@/lib/agent-runtime/models";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { getSession } from "@/lib/db/sessions";
import { PATH_PARAM_UNSUPPORTED } from "@/lib/db/start-session";

vi.mock("@/lib/auth/auth-state", () => ({
	getAuthState: vi.fn(),
}));

const dir = mkdtempSync(join(tmpdir(), "web-next-sessions-route-"));
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

async function post(body: unknown) {
	const { POST } = await import("./route");
	return POST(
		new Request("http://test/api/sessions", {
			method: "POST",
			body: JSON.stringify(body),
		}),
	);
}

describe("POST /api/sessions", () => {
	test("401s when unauthenticated, 403s when not allowlisted", async () => {
		vi.mocked(getAuthState).mockResolvedValue({ kind: "unauthenticated" });
		expect((await post({ title: "x" })).status).toBe(401);
		vi.mocked(getAuthState).mockResolvedValue({ kind: "forbidden", login: "nope" });
		expect((await post({ title: "x" })).status).toBe(403);
	});

	test("creates a session on the DEFAULT model with the given title/provider", async () => {
		const res = await post({ title: "validation: real-turn probe t0", provider: "vercel" });
		expect(res.status).toBe(201);
		const body = await res.json();
		expect(body).toMatchObject({
			title: "validation: real-turn probe t0",
			provider: "vercel",
			model: DEFAULT_MODEL,
			status: "active",
		});
		const row = await getSession(getDatabase(), body.id);
		expect(row?.model).toBe(DEFAULT_MODEL);
		expect(row?.repoId).toBeNull();
		expect(row?.ownerLogin).toBe("fairchild");
	});

	test("defaults: empty title, the configured default provider", async () => {
		const res = await post({});
		expect(res.status).toBe(201);
		const body = await res.json();
		expect(body.title).toBe("");
		expect(body.provider).toBe("mock");
	});

	test("rejects an unknown provider and an unknown field", async () => {
		expect((await post({ provider: "skynet" })).status).toBe(400);
		expect((await post({ branch: "main" })).status).toBe(400);
	});

	test("rejects the reserved path field with the contract message", async () => {
		const res = await post({ path: "/tmp/checkout" });
		expect(res.status).toBe(400);
		await expect(res.json()).resolves.toEqual({
			error: PATH_PARAM_UNSUPPORTED,
		});
	});

	// Fixture repo directory (no App creds + bypass) keeps GitHub validation
	// hermetic — fairchild/workspaces resolves, anything else 404s.
	describe("optional repo", () => {
		beforeEach(() => {
			vi.stubEnv("AUTH_BYPASS", "1");
			vi.stubEnv("GITHUB_WEB_WORKSPACES_APP_ID", "");
			vi.stubEnv("GITHUB_APP_PRIVATE_KEY", "");
			return () => vi.unstubAllEnvs();
		});

		test("resolves and records the repo like the UI create path", async () => {
			const res = await post({ repo: "fairchild/workspaces", title: "embed t0" });
			expect(res.status).toBe(201);
			const body = await res.json();
			expect(body.title).toBe("embed t0");
			const row = await getSession(getDatabase(), body.id);
			expect(row?.repoId).toBe("fairchild/workspaces");
			expect(row?.ownerLogin).toBe("fairchild");
		});

		test("400s a malformed repo, 404s an unresolvable one — never a 500", async () => {
			expect((await post({ repo: "not-a-repo" })).status).toBe(400);
			expect((await post({ repo: 42 })).status).toBe(400);
			const res = await post({ repo: "fairchild/not-a-real-repo" });
			expect(res.status).toBe(404);
			const body = await res.json();
			expect(body.error).toContain("doesn't exist or isn't accessible");
		});
	});

	test("rejects a non-string or over-long title, and a non-JSON body", async () => {
		expect((await post({ title: 42 })).status).toBe(400);
		expect((await post({ title: "x".repeat(500) })).status).toBe(400);
		const { POST } = await import("./route");
		const res = await POST(
			new Request("http://test/api/sessions", { method: "POST", body: "not json" }),
		);
		expect(res.status).toBe(400);
	});
});
