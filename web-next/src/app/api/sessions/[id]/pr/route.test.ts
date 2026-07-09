import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeEach, describe, expect, test, vi } from "vitest";
import {
	openSessionPullRequest,
	SessionPrError,
} from "@/lib/agent-runtime/session-pr";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { ensureRepo } from "@/lib/db/repos";
import { createSession, updateSession } from "@/lib/db/sessions";

vi.mock("@/lib/auth/auth-state", () => ({
	getAuthState: vi.fn(),
}));

vi.mock("@/lib/agent-runtime/session-pr", async () => {
	const actual = await vi.importActual<typeof import("@/lib/agent-runtime/session-pr")>(
		"@/lib/agent-runtime/session-pr",
	);
	return { ...actual, openSessionPullRequest: vi.fn() };
});

const dir = mkdtempSync(join(tmpdir(), "web-next-pr-route-"));
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
	vi.mocked(openSessionPullRequest).mockReset();
});

async function postPr(id: string) {
	const { POST } = await import("./route");
	return POST(new Request(`http://spaces.test/api/sessions/${id}/pr`, { method: "POST" }), {
		params: Promise.resolve({ id }),
	});
}

let seq = 0;
async function freshVercelSession(ownerLogin: string | null = "fairchild") {
	const repo = await ensureRepo(getDatabase(), "fairchild/workspaces", "main");
	const id = `pr-route-${++seq}`;
	await createSession(getDatabase(), {
		id,
		repoId: repo.id,
		ownerLogin,
		provider: "vercel",
	});
	await updateSession(getDatabase(), id, {
		claudeSessionId: "harness-1",
		resumeState: '{"parked":true}',
		hasBranchWork: true,
	});
	return id;
}

describe("POST /api/sessions/[id]/pr", () => {
	test("401s when unauthenticated and 404s for an unknown session", async () => {
		vi.mocked(getAuthState).mockResolvedValue({ kind: "unauthenticated" });
		expect((await postPr("whatever")).status).toBe(401);

		vi.mocked(getAuthState).mockResolvedValue(AUTHORIZED);
		expect((await postPr("missing")).status).toBe(404);
	});

	test("403s for a session owned by another login", async () => {
		const id = await freshVercelSession("octocat");

		const res = await postPr(id);

		expect(res.status).toBe(403);
		expect(openSessionPullRequest).not.toHaveBeenCalled();
	});

	test("delegates to the PR service with repo and session URL", async () => {
		const id = await freshVercelSession();
		vi.mocked(openSessionPullRequest).mockResolvedValue({
			hasBranchWork: false,
			pullRequest: {
				number: 123,
				url: "https://github.com/fairchild/workspaces/pull/123",
				state: "open",
			},
		});

		const res = await postPr(id);

		expect(res.status).toBe(200);
		expect(await res.json()).toMatchObject({
			hasBranchWork: false,
			pullRequest: { number: 123, state: "open" },
		});
		expect(openSessionPullRequest).toHaveBeenCalledWith(
			expect.objectContaining({
				repo: expect.objectContaining({ fullName: "fairchild/workspaces" }),
				sessionUrl: `http://spaces.test/sessions/${id}`,
			}),
		);
	});

	test("returns structured JSON for provider refusal", async () => {
		const id = await freshVercelSession();
		vi.mocked(openSessionPullRequest).mockRejectedValue(
			new SessionPrError(
				"unsupported_provider",
				"PRs from host-provider sessions need a separate credential story.",
				409,
			),
		);

		const res = await postPr(id);

		expect(res.status).toBe(409);
		expect(await res.json()).toEqual({
			code: "unsupported_provider",
			error: "PRs from host-provider sessions need a separate credential story.",
		});
	});
});
