import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { type DatabaseHandle, openDatabase } from "../db/client";
import { ensureRepo } from "../db/repos";
import {
	appendEvents,
	createSession,
	getSession,
	updateSession,
} from "../db/sessions";
import {
	composeSessionPullRequestBody,
	openSessionPullRequest,
	SessionPrError,
} from "./session-pr";
import {
	PullRequestBranchMissingRemote,
	openPullRequestFromGitHubApi,
	openPullRequestFromVercelSession,
	PullRequestCommandFailed,
} from "./vercel-provider";

vi.mock("./vercel-provider", () => ({
	MISSING_REMOTE_BRANCH_MESSAGE:
		"branch not on remote — run another turn to checkpoint and push",
	sessionBranch: (id: string) => `agent/session-${id.slice(0, 8)}`,
	openPullRequestFromGitHubApi: vi.fn(),
	openPullRequestFromVercelSession: vi.fn(),
	PullRequestBranchMissingRemote: class PullRequestBranchMissingRemote extends Error {
		constructor() {
			super("branch not on remote — run another turn to checkpoint and push");
		}
	},
	PullRequestCommandFailed: class PullRequestCommandFailed extends Error {
		constructor(
			message: string,
			readonly resume: unknown,
		) {
			super(message);
		}
	},
}));

let handle: DatabaseHandle | undefined;
let dir: string | undefined;

function freshDb(): DatabaseHandle {
	dir = mkdtempSync(join(tmpdir(), "web-next-pr-"));
	handle = openDatabase(`file:${join(dir, "test.db")}`);
	return handle;
}

afterEach(async () => {
	await handle?.db.destroy();
	handle = undefined;
	if (dir) rmSync(dir, { recursive: true, force: true });
	dir = undefined;
});

beforeEach(() => {
	vi.mocked(openPullRequestFromVercelSession).mockReset();
	vi.mocked(openPullRequestFromGitHubApi).mockReset();
});

describe("composeSessionPullRequestBody", () => {
	test("includes session identity, turn receipts, and the session link", async () => {
		const db = freshDb();
		const repo = await ensureRepo(db, "fairchild/workspaces", "main");
		const session = await createSession(db, {
			id: "abcdef123456",
			repoId: repo.id,
			title: "Fix session PRs",
			provider: "vercel",
		});
		await appendEvents(db, session.id, [
			{ role: "user", chunk: { type: "text", content: "Open the PR flow" } },
			{ role: "assistant", chunk: { type: "tool_use", content: "Bash" } },
			{ role: "assistant", chunk: { type: "done", content: "", metadata: { durationMs: 1200, tokenCount: 44 } } },
		]);

		const body = await composeSessionPullRequestBody({
			handle: db,
			session,
			repo,
			sessionUrl: "https://spaces.test/sessions/abcdef123456",
		});

		expect(body).toContain("Draft PR opened from Spaces session abcdef123456");
		expect(body).toContain("Session: https://spaces.test/sessions/abcdef123456");
		expect(body).toContain("Branch: agent/session-abcdef12");
		expect(body).toContain("1. Open the PR flow");
		expect(body).toContain("Claude 1 tools, 1.2s, 44 tokens");
	});
});

describe("openSessionPullRequest", () => {
	test("returns a persisted PR without running commands and clears stale branch work", async () => {
		const db = freshDb();
		const repo = await ensureRepo(db, "fairchild/workspaces", "main");
		const session = await createSession(db, {
			id: "s-idempotent",
			repoId: repo.id,
			provider: "vercel",
		});
		await updateSession(db, session.id, {
			hasBranchWork: true,
			pullRequest: {
				number: 12,
				url: "https://github.com/fairchild/workspaces/pull/12",
				state: "open",
			},
		});

		const result = await openSessionPullRequest({
			handle: db,
			session: (await getSession(db, session.id)) ?? session,
			repo,
			sessionUrl: "https://spaces.test/sessions/s-idempotent",
		});

		expect(result.pullRequest.number).toBe(12);
		expect(result.hasBranchWork).toBe(false);
		expect((await getSession(db, session.id))?.hasBranchWork).toBe(false);
		expect(openPullRequestFromVercelSession).not.toHaveBeenCalled();
		expect(openPullRequestFromGitHubApi).not.toHaveBeenCalled();
	});

	test("refuses host-provider sessions with a credential-story error", async () => {
		const db = freshDb();
		const repo = await ensureRepo(db, "fairchild/workspaces", "main");
		const session = await createSession(db, {
			id: "s-host",
			repoId: repo.id,
			provider: "host",
		});

		await expect(
			openSessionPullRequest({
				handle: db,
				session,
				repo,
				sessionUrl: "https://spaces.test/sessions/s-host",
			}),
		).rejects.toMatchObject({
			code: "unsupported_provider",
			status: 409,
		} satisfies Partial<SessionPrError>);
		expect(openPullRequestFromVercelSession).not.toHaveBeenCalled();
	});

	test("creates the PR through GitHub API when the pushed branch exists but the sandbox is gone", async () => {
		const db = freshDb();
		const repo = await ensureRepo(db, "fairchild/workspaces", "main");
		const session = await createSession(db, {
			id: "abcdef123456",
			repoId: repo.id,
			title: "Ship parked branch",
			provider: "vercel",
		});
		await updateSession(db, session.id, { hasBranchWork: true });
		vi.mocked(openPullRequestFromGitHubApi).mockResolvedValue({
			number: 100,
			url: "https://github.com/fairchild/workspaces/pull/100",
			state: "open",
		});

		const result = await openSessionPullRequest({
			handle: db,
			session: (await getSession(db, session.id)) ?? session,
			repo,
			sessionUrl: "https://spaces.test/sessions/abcdef123456",
		});

		expect(result).toEqual({
			hasBranchWork: false,
			pullRequest: {
				number: 100,
				url: "https://github.com/fairchild/workspaces/pull/100",
				state: "open",
			},
		});
		expect(openPullRequestFromVercelSession).not.toHaveBeenCalled();
		expect(openPullRequestFromGitHubApi).toHaveBeenCalledWith(
			expect.objectContaining({
				sessionId: session.id,
				title: "Ship parked branch",
				repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
			}),
		);
		const updated = await getSession(db, session.id);
		expect(updated?.hasBranchWork).toBe(false);
		expect(updated?.pullRequest?.number).toBe(100);
	});

	test("runs the sandbox PR command, persists the PR, and clears branch work", async () => {
		const db = freshDb();
		const repo = await ensureRepo(db, "fairchild/workspaces", "main");
		const session = await createSession(db, {
			id: "abcdef123456",
			repoId: repo.id,
			title: "Ship PR action",
			provider: "vercel",
		});
		await updateSession(db, session.id, {
			claudeSessionId: "harness-1",
			resumeState: '{"parked":true}',
			hasBranchWork: true,
		});
		vi.mocked(openPullRequestFromVercelSession).mockResolvedValue({
			number: 99,
			url: "https://github.com/fairchild/workspaces/pull/99",
			state: "open",
			resume: {
				harnessSessionId: "harness-1",
				resumeState: '{"parked":"again"}',
			},
		});

		const result = await openSessionPullRequest({
			handle: db,
			session: (await getSession(db, session.id)) ?? session,
			repo,
			sessionUrl: "https://spaces.test/sessions/abcdef123456",
		});

		expect(result).toEqual({
			hasBranchWork: false,
			pullRequest: {
				number: 99,
				url: "https://github.com/fairchild/workspaces/pull/99",
				state: "open",
			},
		});
		expect(openPullRequestFromVercelSession).toHaveBeenCalledWith(
			expect.objectContaining({
				sessionId: session.id,
				title: "Ship PR action",
				repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
			}),
		);
		const updated = await getSession(db, session.id);
		expect(updated?.hasBranchWork).toBe(false);
		expect(updated?.pullRequest?.number).toBe(99);
		expect(updated?.resumeState).toBe('{"parked":"again"}');
	});

	test("falls back to the GitHub API when sandbox resume is expired", async () => {
		const db = freshDb();
		const repo = await ensureRepo(db, "fairchild/workspaces", "main");
		const session = await createSession(db, {
			id: "abcdef123456",
			repoId: repo.id,
			title: "Expired sandbox PR",
			provider: "vercel",
		});
		await updateSession(db, session.id, {
			claudeSessionId: "harness-1",
			resumeState: '{"parked":true}',
			hasBranchWork: true,
		});
		vi.mocked(openPullRequestFromVercelSession).mockRejectedValue(
			new PullRequestCommandFailed("sandbox expired", null),
		);
		vi.mocked(openPullRequestFromGitHubApi).mockResolvedValue({
			number: 101,
			url: "https://github.com/fairchild/workspaces/pull/101",
			state: "open",
		});

		const result = await openSessionPullRequest({
			handle: db,
			session: (await getSession(db, session.id)) ?? session,
			repo,
			sessionUrl: "https://spaces.test/sessions/abcdef123456",
		});

		expect(result.pullRequest.number).toBe(101);
		expect(openPullRequestFromGitHubApi).toHaveBeenCalled();
		const updated = await getSession(db, session.id);
		expect(updated?.hasBranchWork).toBe(false);
		expect(updated?.claudeSessionId).toBeNull();
		expect(updated?.resumeState).toBeNull();
	});

	test("maps a missing remote branch from the API fallback to operator guidance", async () => {
		const db = freshDb();
		const repo = await ensureRepo(db, "fairchild/workspaces", "main");
		const session = await createSession(db, {
			id: "abcdef123456",
			repoId: repo.id,
			title: "Open missing branch",
			provider: "vercel",
		});
		await updateSession(db, session.id, { hasBranchWork: true });
		vi.mocked(openPullRequestFromGitHubApi).mockRejectedValue(
			new PullRequestBranchMissingRemote(),
		);

		await expect(
			openSessionPullRequest({
				handle: db,
				session: (await getSession(db, session.id)) ?? session,
				repo,
				sessionUrl: "https://spaces.test/sessions/abcdef123456",
			}),
		).rejects.toMatchObject({
			code: "branch_not_on_remote",
			message: "branch not on remote — run another turn to checkpoint and push",
			status: 409,
		} satisfies Partial<SessionPrError>);
		expect(openPullRequestFromGitHubApi).toHaveBeenCalled();
	});
});
