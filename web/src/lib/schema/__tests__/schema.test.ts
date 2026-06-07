import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Fresh in-memory libsql DB per test so the bootstrap runs against a real
// engine without persisting between runs.
beforeEach(() => {
	vi.stubEnv("TURSO_DATABASE_URL", ":memory:");
});

afterEach(() => {
	vi.unstubAllEnvs();
	vi.resetModules();
});

// db + schema must come from the same fresh module graph so getTurso() in the
// test shares the singleton client ensureSchema() bootstraps.
async function load() {
	vi.resetModules();
	const db = await import("../../db");
	const schema = await import("../index");
	return { ...db, ...schema };
}

describe("ensureSchema", () => {
	it("builds every table on a fresh database and records the baseline", async () => {
		const { ensureSchema, getTurso } = await load();
		await ensureSchema();

		const tables = await getTurso().execute(
			"SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
		);
		const names = tables.rows.map((r) => String(r.name));
		for (const expected of [
			"agent_sessions",
			"base_snapshots",
			"chat_messages",
			"managed_agents_cache",
			"managed_pr_review_projections",
			"managed_pr_review_runs",
			"schema_migrations",
			"terminal_access_tickets",
			"user_repos",
			"webhook_events",
			"workspaces",
		]) {
			expect(names).toContain(expected);
		}

		const applied = await getTurso().execute(
			"SELECT id FROM schema_migrations",
		);
		expect(applied.rows.map((r) => String(r.id))).toEqual(["0001_baseline"]);
	});

	it("re-running the migration runner is a no-op (idempotent skip, no duplicate record)", async () => {
		const { ensureSchema, resetSchemaForTests, getTurso } = await load();
		await ensureSchema();

		// Forget the memoized promise so the runner actually executes again; it
		// must see the baseline already applied and skip it rather than re-run.
		resetSchemaForTests();
		await expect(ensureSchema()).resolves.toBeUndefined();

		const applied = await getTurso().execute(
			"SELECT id FROM schema_migrations",
		);
		expect(applied.rows).toHaveLength(1);
	});

	it("converges an existing database with a narrower schema without losing data", async () => {
		const { ensureSchema, getTurso } = await load();
		const turso = getTurso();

		// A database that already holds some tables with a narrower column set,
		// real rows, and no schema_migrations entry.
		await turso.execute(
			"CREATE TABLE webhook_events (id TEXT PRIMARY KEY, type TEXT NOT NULL, action TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '', repo TEXT NOT NULL DEFAULT 'unknown', timestamp TEXT NOT NULL)",
		);
		await turso.execute(
			"INSERT INTO webhook_events (id, type, timestamp) VALUES ('e1', 'push', '2026-01-01T00:00:00Z')",
		);
		await turso.execute(
			"CREATE TABLE agent_sessions (id TEXT PRIMARY KEY, repo TEXT NOT NULL, agent_name TEXT NOT NULL, compute_backend TEXT NOT NULL, thread_id TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, last_activity_at TEXT NOT NULL)",
		);
		await turso.execute(
			"INSERT INTO agent_sessions (id, repo, agent_name, compute_backend, thread_id, status, created_at, last_activity_at) VALUES ('s1', 'o/r', 'terminal', 'vercel', 't1', 'active', '2026-01-01', '2026-01-01')",
		);
		await turso.execute(
			"CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL, created_at TEXT NOT NULL, last_accessed_at TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'stopped', backend_identifier TEXT NOT NULL DEFAULT 'local', synced_at TEXT NOT NULL)",
		);
		await turso.execute(
			"INSERT INTO workspaces (id, name, path, created_at, last_accessed_at, synced_at) VALUES ('w1', 'ws', '/p', '2026-01-01', '2026-01-01', '2026-01-01')",
		);

		await expect(ensureSchema()).resolves.toBeUndefined();

		// Missing column added with its default; existing row preserved + backfilled.
		const ev = await turso.execute(
			"SELECT id, payload FROM webhook_events WHERE id = 'e1'",
		);
		expect(ev.rows).toHaveLength(1);
		expect(String(ev.rows[0].payload)).toBe("{}");

		// New columns added; the terminal→shell data migration applied.
		const sess = await turso.execute(
			"SELECT agent_name, user_id, snapshot_id FROM agent_sessions WHERE id = 's1'",
		);
		expect(String(sess.rows[0].agent_name)).toBe("shell");
		expect(sess.rows[0].user_id).toBeNull();

		// owner_id added and backfilled to the default owner.
		const ws = await turso.execute(
			"SELECT owner_id FROM workspaces WHERE id = 'w1'",
		);
		expect(String(ws.rows[0].owner_id)).toBe("default");

		const applied = await turso.execute("SELECT id FROM schema_migrations");
		expect(applied.rows.map((r) => String(r.id))).toContain("0001_baseline");
	});
});
