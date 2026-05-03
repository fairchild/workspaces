import { beforeEach, describe, expect, it } from "vitest";
import type { AgentSession } from "../types";

let mod: typeof import("../agent-sessions");
let testSeq = 0;

/** Unique threadId per test to prevent cross-test leakage in shared in-memory DB. */
function uniqueThread(): string {
	return `thread-${Date.now()}-${++testSeq}`;
}

function makeSession(overrides: Partial<AgentSession> = {}): AgentSession {
	return {
		id: `test-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
		userId: "user-1",
		repo: "owner/repo",
		agentName: "test-agent",
		computeBackend: "vercel-sandbox",
		computeInstanceId: null,
		snapshotId: null,
		claudeSessionId: null,
		threadId: uniqueThread(),
		discussionId: null,
		status: "starting",
		createdAt: new Date().toISOString(),
		lastActivityAt: new Date().toISOString(),
		...overrides,
	};
}

beforeEach(async () => {
	mod = await import("../agent-sessions");
});

describe("snapshot session lifecycle", () => {
	it("stores and retrieves snapshotId", async () => {
		const session = makeSession();
		await mod.createSession(session);
		await mod.updateSnapshotId(session.id, "snap-abc");

		const loaded = await mod.getSession(session.id);
		expect(loaded?.snapshotId).toBe("snap-abc");
	});

	it("stores and retrieves claudeSessionId", async () => {
		const session = makeSession({ claudeSessionId: "claude-uuid-1" });
		await mod.createSession(session);

		const loaded = await mod.getSession(session.id);
		expect(loaded?.claudeSessionId).toBe("claude-uuid-1");
	});

	it("getSnapshotSessionForThread finds snapshotted sessions", async () => {
		const session = makeSession({
			status: "snapshotted",
			snapshotId: "snap-1",
		});
		await mod.createSession(session);

		const found = await mod.getSnapshotSessionForThread(
			session.userId,
			session.repo,
			session.agentName,
			session.threadId,
		);
		expect(found?.id).toBe(session.id);
		expect(found?.snapshotId).toBe("snap-1");
	});

	it("getSnapshotSessionForThread ignores completed sessions", async () => {
		const session = makeSession({
			status: "completed",
			snapshotId: "snap-old",
		});
		await mod.createSession(session);

		const found = await mod.getSnapshotSessionForThread(
			session.userId,
			session.repo,
			session.agentName,
			session.threadId,
		);
		expect(found).toBeNull();
	});

	it("getSnapshotSessionForThread returns most recent", async () => {
		const sharedThread = uniqueThread();
		const older = makeSession({
			status: "snapshotted",
			snapshotId: "snap-old",
			threadId: sharedThread,
			lastActivityAt: "2025-01-01T00:00:00Z",
		});
		const newer = makeSession({
			status: "snapshotted",
			snapshotId: "snap-new",
			threadId: sharedThread,
			lastActivityAt: "2025-06-01T00:00:00Z",
		});
		await mod.createSession(older);
		await mod.createSession(newer);

		const found = await mod.getSnapshotSessionForThread(
			newer.userId,
			older.repo,
			older.agentName,
			sharedThread,
		);
		expect(found?.id).toBe(newer.id);
	});
});

describe("claimSnapshotSession", () => {
	it("transitions snapshotted → streaming and returns true", async () => {
		const session = makeSession({
			status: "snapshotted",
			snapshotId: "snap-1",
		});
		await mod.createSession(session);

		const claimed = await mod.claimSnapshotSession(session.id);
		expect(claimed).toBe(true);

		const loaded = await mod.getSession(session.id);
		expect(loaded?.status).toBe("streaming");
	});

	it("returns false for non-snapshotted session", async () => {
		const session = makeSession({ status: "active" });
		await mod.createSession(session);

		const claimed = await mod.claimSnapshotSession(session.id);
		expect(claimed).toBe(false);

		const loaded = await mod.getSession(session.id);
		expect(loaded?.status).toBe("active");
	});

	it("second claim on same session returns false (atomic)", async () => {
		const session = makeSession({
			status: "snapshotted",
			snapshotId: "snap-1",
		});
		await mod.createSession(session);

		const first = await mod.claimSnapshotSession(session.id);
		const second = await mod.claimSnapshotSession(session.id);

		expect(first).toBe(true);
		expect(second).toBe(false);
	});
});

describe("getActiveSessionForThread", () => {
	it("finds active sessions", async () => {
		const session = makeSession({
			status: "active",
			computeInstanceId: "inst-1",
		});
		await mod.createSession(session);

		const found = await mod.getActiveSessionForThread(
			session.userId,
			session.repo,
			session.agentName,
			session.threadId,
		);
		expect(found?.id).toBe(session.id);
	});

	it("does not find snapshotted sessions", async () => {
		const session = makeSession({
			status: "snapshotted",
			snapshotId: "snap-1",
		});
		await mod.createSession(session);

		const found = await mod.getActiveSessionForThread(
			session.userId,
			session.repo,
			session.agentName,
			session.threadId,
		);
		expect(found).toBeNull();
	});

	it("scopes active sessions by user", async () => {
		const sharedThread = uniqueThread();
		const userOne = makeSession({
			userId: "user-1",
			status: "active",
			computeInstanceId: "inst-user-1",
			threadId: sharedThread,
		});
		const userTwo = makeSession({
			userId: "user-2",
			status: "active",
			computeInstanceId: "inst-user-2",
			threadId: sharedThread,
		});
		await mod.createSession(userOne);
		await mod.createSession(userTwo);

		const found = await mod.getActiveSessionForThread(
			"user-1",
			userOne.repo,
			userOne.agentName,
			sharedThread,
		);

		expect(found?.id).toBe(userOne.id);
		expect(found?.computeInstanceId).toBe("inst-user-1");
	});
});

describe("repo session lookups", () => {
	it("lists only the current user's live sessions for a repo", async () => {
		const repo = `owner/repo-${uniqueThread()}`;
		const userOne = makeSession({
			userId: "user-1",
			repo,
			agentName: "april",
			status: "active",
			computeInstanceId: "inst-user-1",
		});
		const userTwo = makeSession({
			userId: "user-2",
			repo,
			agentName: "april",
			status: "active",
			computeInstanceId: "inst-user-2",
		});
		await mod.createSession(userOne);
		await mod.createSession(userTwo);

		const sessions = await mod.getSessionsForRepo("user-1", userOne.repo);

		expect(sessions.map((session) => session.id)).toEqual([userOne.id]);
	});

	it("finds an agent session only for the current user", async () => {
		const repo = `owner/repo-${uniqueThread()}`;
		const userOne = makeSession({
			userId: "user-1",
			repo,
			agentName: "april",
			status: "active",
			computeInstanceId: "inst-user-1",
		});
		const userTwo = makeSession({
			userId: "user-2",
			repo,
			agentName: "april",
			status: "active",
			computeInstanceId: "inst-user-2",
			lastActivityAt: "2030-01-01T00:00:00Z",
		});
		await mod.createSession(userOne);
		await mod.createSession(userTwo);

		const found = await mod.getSessionForAgent(
			"user-1",
			userOne.repo,
			userOne.agentName,
		);

		expect(found?.id).toBe(userOne.id);
	});

	it("finds a transcript session by instance id only for the owner", async () => {
		const session = makeSession({
			userId: "user-1",
			status: "active",
			computeInstanceId: "shared-instance",
		});
		await mod.createSession(session);

		await expect(
			mod.getSessionByInstanceId("user-2", "shared-instance"),
		).resolves.toBeNull();
		await expect(
			mod.getSessionByInstanceId("user-1", "shared-instance"),
		).resolves.toMatchObject({ id: session.id });
	});
});
