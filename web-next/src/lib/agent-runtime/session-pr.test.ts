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
import { openPullRequestFromVercelSession } from "./vercel-provider";

vi.mock("./vercel-provider", () => ({
	sessionBranch: (id: string) => `agent/session-${id.slice(0, 8)}`,
	openPullRequestFromVercelSession: vi.fn(),
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
	test("returns a persisted PR without running the sandbox command when no work is ahead", async () => {
		const db = freshDb();
		const repo = await ensureRepo(db, "fairchild/workspaces", "main");
		const session = await createSession(db, {
			id: "s-idempotent",
			repoId: repo.id,
			provider: "vercel",
		});
		await updateSession(db, session.id, {
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
		expect(result.hasUnpushedWork).toBe(false);
		expect(openPullRequestFromVercelSession).not.toHaveBeenCalled();
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

	test("runs the sandbox PR command, persists the PR, and clears unpushed work", async () => {
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
			hasUnpushedWork: true,
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
			hasUnpushedWork: false,
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
		expect(updated?.hasUnpushedWork).toBe(false);
		expect(updated?.pullRequest?.number).toBe(99);
		expect(updated?.resumeState).toBe('{"parked":"again"}');
	});
});
