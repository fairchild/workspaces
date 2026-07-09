/*
 * GET /new — the embedded shell's session-create deep link (#987): repo
 * resolution through the shared UI write path, 302 to the session, readable
 * 4xx failures, and the reserved `path=` rejection. Same harness pattern as
 * the api/sessions tests: mocked auth state, real DB, AUTH_BYPASS fixture
 * directory for deterministic GitHub validation.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeEach, describe, expect, test, vi } from "vitest";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { getSession } from "@/lib/db/sessions";
import { PATH_PARAM_UNSUPPORTED } from "@/lib/db/start-session";

vi.mock("@/lib/auth/auth-state", () => ({
	getAuthState: vi.fn(),
}));

const dir = mkdtempSync(join(tmpdir(), "web-next-new-route-"));
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
	// Fixture repo directory (no App creds + bypass) keeps GitHub validation
	// hermetic — fairchild/workspaces resolves, anything else 404s.
	vi.stubEnv("AUTH_BYPASS", "1");
	vi.stubEnv("GITHUB_WEB_WORKSPACES_APP_ID", "");
	vi.stubEnv("GITHUB_APP_PRIVATE_KEY", "");
	return () => vi.unstubAllEnvs();
});

async function get(query: string, headers?: Record<string, string>) {
	const { GET } = await import("./route");
	return GET(new Request(`http://localhost:3100/new${query}`, { headers }));
}

describe("GET /new", () => {
	test("creates a session on the repo and 302s to it", async () => {
		const res = await get("?repo=fairchild/workspaces");
		expect(res.status).toBe(302);
		const location = res.headers.get("location") ?? "";
		const id = location.split("/sessions/")[1];
		expect(id).toBeTruthy();
		const row = await getSession(getDatabase(), id);
		expect(row).toMatchObject({
			repoId: "fairchild/workspaces",
			ownerLogin: "fairchild",
			title: "",
		});
	});

	test("records a cleaned title when given", async () => {
		const res = await get(
			"?repo=fairchild/workspaces&title=embed%20%20shell%0Asmoke",
		);
		expect(res.status).toBe(302);
		const id = (res.headers.get("location") ?? "").split("/sessions/")[1];
		const row = await getSession(getDatabase(), id);
		expect(row?.title).toBe("embed shell smoke");
	});

	test("rejects a missing or malformed repo with a readable 400", async () => {
		for (const query of ["", "?repo=", "?repo=not-a-repo", "?repo=a/b/c"]) {
			const res = await get(query);
			expect(res.status, query).toBe(400);
			expect(await res.text()).toContain("owner/name");
		}
	});

	test("404s a repo GitHub can't resolve, without a 500", async () => {
		const res = await get("?repo=fairchild/not-a-real-repo");
		expect(res.status).toBe(404);
		expect(await res.text()).toContain("doesn't exist or isn't accessible");
	});

	test("rejects an over-long title with a readable 400", async () => {
		const res = await get(`?repo=fairchild/workspaces&title=${"x".repeat(500)}`);
		expect(res.status).toBe(400);
	});

	test("rejects the reserved path= param with the contract message", async () => {
		const res = await get("?repo=fairchild/workspaces&path=/tmp/checkout");
		expect(res.status).toBe(400);
		expect(await res.text()).toContain(PATH_PARAM_UNSUPPORTED);
	});

	test("refuses an explicit cross-site navigation — no CSRF junk sessions", async () => {
		const res = await get("?repo=fairchild/workspaces", {
			"sec-fetch-site": "cross-site",
		});
		expect(res.status).toBe(403);
		expect(await res.text()).toContain("cross-site");
	});

	test("still creates when fetch metadata is absent or none — the WKWebView flow", async () => {
		for (const headers of [undefined, { "sec-fetch-site": "none" }]) {
			const res = await get("?repo=fairchild/workspaces", headers);
			expect(res.status, JSON.stringify(headers ?? {})).toBe(302);
		}
	});

	test("redirects an unauthenticated caller to /sign-in", async () => {
		vi.mocked(getAuthState).mockResolvedValue({ kind: "unauthenticated" });
		const res = await get("?repo=fairchild/workspaces");
		expect(res.status).toBe(302);
		expect(res.headers.get("location")).toContain("/sign-in");
	});
});
