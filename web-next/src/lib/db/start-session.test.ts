import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { DEFAULT_MODEL } from "../agent-runtime/models";
import { type DatabaseHandle, openDatabase } from "./client";
import { ensureRepo, listRepos } from "./repos";
import { listSessions } from "./sessions";
import { isValidRepoFullName, startSession } from "./start-session";

let open: DatabaseHandle | undefined;
let dir: string | undefined;

function freshDb(): DatabaseHandle {
	dir = mkdtempSync(join(tmpdir(), "web-next-db-"));
	open = openDatabase(`file:${join(dir, "test.db")}`);
	return open;
}

afterEach(async () => {
	await open?.db.destroy();
	open = undefined;
	if (dir) rmSync(dir, { recursive: true, force: true });
	dir = undefined;
});

describe("isValidRepoFullName", () => {
	test("accepts owner/name shapes", () => {
		expect(isValidRepoFullName("fairchild/workspaces")).toBe(true);
		expect(isValidRepoFullName("a-b.c_d/e.f-g_h")).toBe(true);
	});

	test("rejects everything else", () => {
		for (const bad of [
			"",
			"workspaces",
			"/workspaces",
			"fairchild/",
			"a/b/c",
			"owner/name with spaces",
			"-leading/dash",
			"owner/name\n",
		]) {
			expect(isValidRepoFullName(bad), bad).toBe(false);
		}
	});
});

describe("startSession", () => {
	test("creates the repo on first use and an empty active session on it", async () => {
		const handle = freshDb();
		const session = await startSession(handle, "fairchild/workspaces");
		expect(session).toMatchObject({
			repoId: "fairchild/workspaces",
			title: "",
			provider: "mock",
			status: "active",
			model: DEFAULT_MODEL,
		});
		expect(session.id).toBeTruthy();
		expect((await listRepos(handle)).map((r) => r.fullName)).toEqual([
			"fairchild/workspaces",
		]);
	});

	test("reuses an existing repo instead of duplicating it", async () => {
		const handle = freshDb();
		const repo = await ensureRepo(handle, "fairchild/workspaces");
		const first = await startSession(handle, "fairchild/workspaces");
		const second = await startSession(handle, " fairchild/workspaces ");
		expect(first.repoId).toBe(repo.id);
		expect(second.repoId).toBe(repo.id);
		expect(await listRepos(handle)).toHaveLength(1);
	});

	test("rejects invalid names without writing anything", async () => {
		const handle = freshDb();
		await expect(startSession(handle, "not a repo")).rejects.toThrow(
			/owner\/name/,
		);
		expect(await listRepos(handle)).toHaveLength(0);
		expect(await listSessions(handle)).toHaveLength(0);
	});
});

describe("listSessions", () => {
	test("orders by last activity, newest first, with the repo name joined", async () => {
		const handle = freshDb();
		const a = await startSession(handle, "fairchild/workspaces");
		const b = await startSession(handle, "fairchild/dotfiles");
		// Stagger activity explicitly — same-millisecond creations tie.
		await handle.db
			.updateTable("sessions")
			.set({ last_activity_at: "2026-07-03T01:00:00.000Z" })
			.where("id", "=", a.id)
			.execute();
		await handle.db
			.updateTable("sessions")
			.set({ last_activity_at: "2026-07-03T02:00:00.000Z" })
			.where("id", "=", b.id)
			.execute();

		const listed = await listSessions(handle);
		expect(listed.map((s) => s.id)).toEqual([b.id, a.id]);
		expect(listed[0].repoFullName).toBe("fairchild/dotfiles");
	});
});
