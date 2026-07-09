import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { DEFAULT_MODEL } from "../agent-runtime/models";
import type { StreamChunk } from "../agent-runtime/stream-chunk";
import { type DatabaseHandle, openDatabase } from "./client";
import {
	type AppendEvent,
	appendEvents,
	createSession,
	deleteSession,
	getSession,
	listSessionFilterOptions,
	listSessions,
	readEvents,
	readTranscript,
	titleSessionIfEmpty,
	updateSession,
} from "./sessions";
import { ensureSchema } from "./schema";

// A throwaway on-disk libSQL DB per test — isolated, and (unlike a bare
// `:memory:` client) it survives the reconnect the driver makes across a
// transaction. Cleaned up in afterEach.
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

function evt(role: AppendEvent["role"], chunk: StreamChunk): AppendEvent {
	return { role, chunk };
}

describe("session store", () => {
	test("migrations apply cleanly and are idempotent", async () => {
		const handle = freshDb();
		// Two sessions in a row exercises ensureSchema twice against one handle.
		await createSession(handle, { id: "a", provider: "mock" });
		await createSession(handle, { id: "b", provider: "mock" });
		const recorded = await handle.client.execute(
			"SELECT id FROM schema_migrations ORDER BY id",
		);
		expect(recorded.rows.map((r) => String(r.id))).toEqual([
			"0001_baseline",
			"0002_auth_tables",
			"0003_session_resume_state",
			"0004_session_model",
			"0005_terminal_tickets",
			"0006_session_owner_login",
			"0007_session_first_user_message",
			"0008_turn_approvals",
			"0009_queued_messages",
			"0010_queued_message_dispatch_order",
			"0011_session_pull_requests",
		]);
	});

	test("creates and reads back a session", async () => {
		const handle = freshDb();
		const created = await createSession(handle, {
			id: "s1",
			repoId: "owner/name",
			ownerLogin: "FairChild",
			title: "Fix the bug",
			provider: "mock",
		});
		expect(created).toMatchObject({
			id: "s1",
			repoId: "owner/name",
			ownerLogin: "fairchild",
			title: "Fix the bug",
			provider: "mock",
			status: "active",
		});
		expect(created.resumeState).toBeNull();
		expect(created.firstUserMessage).toBeNull();
		expect(created.hasUnpushedWork).toBe(false);
		expect(created.pullRequest).toBeNull();
		expect(await getSession(handle, "s1")).toEqual(created);
		expect(await getSession(handle, "missing")).toBeUndefined();
	});

	test("stamps the current-best model by default, and honors an explicit override (#824)", async () => {
		const handle = freshDb();
		const defaulted = await createSession(handle, { id: "s1", provider: "mock" });
		expect(defaulted.model).toBe(DEFAULT_MODEL);

		const overridden = await createSession(handle, {
			id: "s2",
			provider: "mock",
			model: "claude-haiku-4-5",
		});
		expect(overridden.model).toBe("claude-haiku-4-5");
		expect((await getSession(handle, "s2"))?.model).toBe("claude-haiku-4-5");
	});

	test("updateSession persists a model change (#824's picker)", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });
		await updateSession(handle, "s1", { model: "claude-opus-4-8" });
		expect((await getSession(handle, "s1"))?.model).toBe("claude-opus-4-8");
	});

	test("updateSession persists a user-edited title (#823)", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });
		await updateSession(handle, "s1", { title: "My title" });
		expect((await getSession(handle, "s1"))?.title).toBe("My title");
	});

	test("updateSession persists PR metadata and the work-ahead flag (#820)", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "vercel" });

		await updateSession(handle, "s1", {
			hasUnpushedWork: true,
			pullRequest: {
				number: 42,
				url: "https://github.com/fairchild/workspaces/pull/42",
				state: "open",
			},
		});
		let session = await getSession(handle, "s1");
		expect(session?.hasUnpushedWork).toBe(true);
		expect(session?.pullRequest).toEqual({
			number: 42,
			url: "https://github.com/fairchild/workspaces/pull/42",
			state: "open",
		});

		await updateSession(handle, "s1", {
			hasUnpushedWork: false,
			pullRequest: null,
		});
		session = await getSession(handle, "s1");
		expect(session?.hasUnpushedWork).toBe(false);
		expect(session?.pullRequest).toBeNull();
	});

	test("titleSessionIfEmpty sets the title only while it is empty (#823)", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });

		expect(await titleSessionIfEmpty(handle, "s1", "Fix the bug")).toBe(true);
		expect((await getSession(handle, "s1"))?.title).toBe("Fix the bug");

		// A second call — e.g. a later turn, or the #811 concurrent-first-send
		// race — never overwrites the title once it is set.
		expect(await titleSessionIfEmpty(handle, "s1", "Something else entirely")).toBe(
			false,
		);
		expect((await getSession(handle, "s1"))?.title).toBe("Fix the bug");
	});

	test("titleSessionIfEmpty never overwrites a user-edited title", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });
		await updateSession(handle, "s1", { title: "My own title" });

		expect(await titleSessionIfEmpty(handle, "s1", "Derived from a message")).toBe(
			false,
		);
		expect((await getSession(handle, "s1"))?.title).toBe("My own title");
	});

	test("titleSessionIfEmpty is a no-op for a blank derived title", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });
		expect(await titleSessionIfEmpty(handle, "s1", "")).toBe(false);
		expect((await getSession(handle, "s1"))?.title).toBe("");
	});

	test("updateSession persists and clears the harness resume handle", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "vercel" });

		await updateSession(handle, "s1", {
			claudeSessionId: "harness-abc",
			resumeState: '{"type":"resume-session","data":{}}',
		});
		let session = await getSession(handle, "s1");
		expect(session?.claudeSessionId).toBe("harness-abc");
		expect(session?.resumeState).toBe('{"type":"resume-session","data":{}}');

		// A null resumeState clears a stale handle without touching other fields.
		await updateSession(handle, "s1", { resumeState: null });
		session = await getSession(handle, "s1");
		expect(session?.resumeState).toBeNull();
		expect(session?.claudeSessionId).toBe("harness-abc");

		// An empty patch is a no-op.
		await updateSession(handle, "s1", {});
		expect((await getSession(handle, "s1"))?.claudeSessionId).toBe("harness-abc");
	});

	test("appends events with a monotonic per-session seq and round-trips them", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });

		const last = await appendEvents(handle, "s1", [
			evt("user", { type: "text", content: "hi" }),
			evt("assistant", { type: "text", content: "hello" }),
		]);
		expect(last).toBe(2);

		const nextLast = await appendEvents(handle, "s1", [
			evt("assistant", { type: "done", content: "" }),
		]);
		expect(nextLast).toBe(3);

		const events = await readEvents(handle, "s1");
		expect(events.map((e) => e.seq)).toEqual([1, 2, 3]);
		expect(events.map((e) => e.role)).toEqual(["user", "assistant", "assistant"]);
		expect(events[0].chunk).toEqual({ type: "text", content: "hi" });
		expect((await getSession(handle, "s1"))?.firstUserMessage).toBe("hi");

		// Resume cursor: only events after seq 1.
		const tail = await readEvents(handle, "s1", 1);
		expect(tail.map((e) => e.seq)).toEqual([2, 3]);
	});

	test("keeps the projected first user message stable after later user turns", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });
		await appendEvents(handle, "s1", [
			evt("assistant", { type: "status", content: "ready" }),
			evt("user", { type: "text", content: "First request" }),
		]);
		await appendEvents(handle, "s1", [
			evt("user", { type: "text", content: "Second request" }),
		]);

		expect((await getSession(handle, "s1"))?.firstUserMessage).toBe(
			"First request",
		);
	});

	test("listSessions searches titles and projected first user messages, filters, and keeps last activity order", async () => {
		const handle = freshDb();
		await ensureSchema(handle);
		await handle.db
			.insertInto("repos")
			.values([
				{
					id: "repo-a",
					full_name: "fairchild/workspaces",
					default_branch: "main",
					created_at: "2026-01-01T00:00:00.000Z",
				},
				{
					id: "repo-b",
					full_name: "fairchild/services",
					default_branch: "main",
					created_at: "2026-01-01T00:00:00.000Z",
				},
			])
			.execute();
		await createSession(handle, {
			id: "old-title",
			repoId: "repo-a",
			title: "Fix launch crash",
			provider: "mock",
			status: "archived",
		});
		await createSession(handle, {
			id: "middle-message",
			repoId: "repo-b",
			title: "Untitled",
			provider: "mock",
			status: "idle",
		});
		await createSession(handle, {
			id: "new-title",
			repoId: "repo-a",
			title: "Keyboard resume polish",
			provider: "mock",
			status: "active",
		});
		await appendEvents(handle, "old-title", [
			evt("user", { type: "text", content: "Unrelated first message" }),
		]);
		await appendEvents(handle, "middle-message", [
			evt("user", { type: "text", content: "Search the session body" }),
		]);
		await appendEvents(handle, "new-title", [
			evt("user", { type: "text", content: "Resume ergonomics" }),
		]);
		await handle.db
			.updateTable("sessions")
			.set({ last_activity_at: "2026-01-01T00:00:00.000Z" })
			.where("id", "=", "old-title")
			.execute();
		await handle.db
			.updateTable("sessions")
			.set({ last_activity_at: "2026-01-01T00:01:00.000Z" })
			.where("id", "=", "middle-message")
			.execute();
		await handle.db
			.updateTable("sessions")
			.set({ last_activity_at: "2026-01-01T00:02:00.000Z" })
			.where("id", "=", "new-title")
			.execute();

		expect((await listSessions(handle, { query: "body" })).map((s) => s.id)).toEqual([
			"middle-message",
		]);
		expect((await listSessions(handle, { query: "keyboard" })).map((s) => s.id)).toEqual([
			"new-title",
		]);
		expect(
			(await listSessions(handle, { repoId: "repo-a", status: "active" })).map(
				(s) => s.id,
			),
		).toEqual(["new-title"]);
		expect((await listSessions(handle)).map((s) => s.id)).toEqual([
			"new-title",
			"middle-message",
			"old-title",
		]);
	});

	test("listSessions treats LIKE wildcards in the query as literals", async () => {
		const handle = freshDb();
		await ensureSchema(handle);
		await createSession(handle, {
			id: "percent",
			title: "Migration 50% done",
			provider: "mock",
		});
		await createSession(handle, {
			id: "plain",
			title: "Migration 50x done",
			provider: "mock",
		});
		// An unescaped `50%` would match both titles; a literal match is one.
		expect((await listSessions(handle, { query: "50%" })).map((s) => s.id)).toEqual([
			"percent",
		]);
		expect(await listSessions(handle, { query: "_igration" })).toEqual([]);
	});

	test("listSessionFilterOptions returns cheap repo and status facets", async () => {
		const handle = freshDb();
		await ensureSchema(handle);
		await handle.db
			.insertInto("repos")
			.values({
				id: "repo-a",
				full_name: "fairchild/workspaces",
				default_branch: "main",
				created_at: "2026-01-01T00:00:00.000Z",
			})
			.execute();
		await createSession(handle, {
			id: "s1",
			repoId: "repo-a",
			provider: "mock",
			status: "active",
		});
		await createSession(handle, {
			id: "s2",
			provider: "mock",
			status: "idle",
		});

		expect(await listSessionFilterOptions(handle)).toEqual({
			repos: [
				{ value: "__none", label: "no repository", count: 1 },
				{ value: "repo-a", label: "fairchild/workspaces", count: 1 },
			],
			statuses: [
				{ value: "active", label: "active", count: 1 },
				{ value: "idle", label: "idle", count: 1 },
			],
		});
	});

	test("keeps per-session seq independent across sessions", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "mock" });
		await createSession(handle, { id: "s2", provider: "mock" });
		await appendEvents(handle, "s1", [evt("user", { type: "text", content: "a" })]);
		const s2Last = await appendEvents(handle, "s2", [
			evt("user", { type: "text", content: "b" }),
		]);
		expect(s2Last).toBe(1); // s2 starts at 1 regardless of s1
	});

	test("persists a synthetic turn and projects it to the expected transcript", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "sess-1", provider: "mock" });
		await appendEvents(handle, "sess-1", [
			evt("user", { type: "text", content: "Fix the null check" }),
			evt("assistant", { type: "status", content: "Starting sandbox" }),
			evt("assistant", { type: "text", content: "Reading the file. " }),
			evt("assistant", {
				type: "tool_use",
				content: "Read",
				metadata: { toolUseId: "t-1", toolName: "Read", input: { file_path: "session.ts" } },
			}),
			evt("assistant", {
				type: "tool_result",
				content: "return store.get(id);",
				metadata: { toolUseId: "t-1" },
			}),
			evt("assistant", { type: "text", content: "Found it." }),
			evt("assistant", { type: "done", content: "" }),
		]);

		expect(await readTranscript(handle, "sess-1")).toEqual([
			{
				id: "sess-1:1",
				role: "user",
				parts: [{ type: "text", text: "Fix the null check", state: "done" }],
			},
			{
				id: "sess-1:2",
				role: "assistant",
				metadata: {
					author: "Claude",
					turnStats: { toolCount: 1, durationMs: 0 },
				},
				parts: [
					{ type: "text", text: "Reading the file. ", state: "done" },
					{
						type: "dynamic-tool",
						toolName: "Read",
						toolCallId: "t-1",
						state: "output-available",
						input: { file_path: "session.ts" },
						output: "return store.get(id);",
					},
					{ type: "text", text: "Found it.", state: "done" },
				],
			},
		]);
	});
});

describe("deleteSession", () => {
	test("removes the session, its event log, and its terminal tickets together", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "goner", provider: "vercel" });
		await createSession(handle, { id: "keeper", provider: "mock" });
		await appendEvents(handle, "goner", [
			evt("user", { type: "text", content: "hello" }),
			evt("assistant", { type: "done", content: "" }),
		]);
		await appendEvents(handle, "keeper", [evt("user", { type: "text", content: "stay" })]);
		await handle.client.execute({
			sql: "INSERT INTO terminal_tickets (ticket_hash, login, session_id, mode, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
			args: ["h1", "fairchild", "goner", "mock", "2026-01-01", "2026-01-01"],
		});
		await handle.db
			.insertInto("turn_approvals")
			.values({
				session_id: "goner",
				request_id: "approval-1",
				tool_name: "Edit",
				input_summary: "Edit a.ts",
				requested_at: "2026-01-01",
				expires_at: "2026-01-01",
				decision: null,
				decided_at: null,
				decided_by: null,
			})
			.execute();

		expect(await deleteSession(handle, "goner")).toBe(true);
		expect(await getSession(handle, "goner")).toBeUndefined();
		expect(await readEvents(handle, "goner")).toEqual([]);
		const tickets = await handle.client.execute(
			"SELECT ticket_hash FROM terminal_tickets WHERE session_id = 'goner'",
		);
		expect(tickets.rows).toHaveLength(0);
		const approvals = await handle.client.execute(
			"SELECT request_id FROM turn_approvals WHERE session_id = 'goner'",
		);
		expect(approvals.rows).toHaveLength(0);

		// The cascade is scoped: the other session and its log are untouched.
		expect(await getSession(handle, "keeper")).toBeDefined();
		expect(await readEvents(handle, "keeper")).toHaveLength(1);
	});

	test("deleting an unknown session reports false and touches nothing", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "only", provider: "mock" });
		expect(await deleteSession(handle, "ghost")).toBe(false);
		expect(await getSession(handle, "only")).toBeDefined();
	});
});
