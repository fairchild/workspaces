/*
 * Ordered, append-only schema migrations for the session store. Each has a
 * stable `id` and an idempotent `up(db)` that brings a database to the state it
 * describes; `ensureSchema()` (in ./schema) runs the pending ones in order and
 * records each id in `schema_migrations`. Pattern ported from web/src/lib/schema
 * (idempotent DDL, benign-race tolerance); the tables are fresh.
 *
 * Changing the schema: append a new migration with the next ordered id; never
 * edit one that has shipped (it is already recorded and will not re-run). Keep
 * `up` idempotent — `ifNotExists()` throughout — so a partial run re-applies
 * cleanly and two cold starts can overlap.
 */
import type { Kysely } from "kysely";
import type { Database } from "./client";

/** One tracked migration: a stable `id` and an idempotent `up`. */
export interface Migration {
	id: string;
	up(db: Kysely<Database>): Promise<void>;
}

/**
 * Baseline: repos, sessions, and the append-only session_events log.
 */
const baseline: Migration = {
	id: "0001_baseline",
	async up(db) {
		// --- repos ---
		await db.schema
			.createTable("repos")
			.ifNotExists()
			.addColumn("id", "text", (c) => c.primaryKey())
			.addColumn("full_name", "text", (c) => c.notNull())
			.addColumn("default_branch", "text")
			.addColumn("created_at", "text", (c) => c.notNull())
			.execute();

		// --- sessions ---
		await db.schema
			.createTable("sessions")
			.ifNotExists()
			.addColumn("id", "text", (c) => c.primaryKey())
			.addColumn("repo_id", "text")
			.addColumn("title", "text", (c) => c.notNull().defaultTo(""))
			.addColumn("provider", "text", (c) => c.notNull())
			.addColumn("status", "text", (c) => c.notNull().defaultTo("active"))
			.addColumn("claude_session_id", "text")
			.addColumn("created_at", "text", (c) => c.notNull())
			.addColumn("last_activity_at", "text", (c) => c.notNull())
			.execute();
		// Sessions home (#747) lists by recency; index the sort key.
		await db.schema
			.createIndex("idx_sessions_last_activity")
			.ifNotExists()
			.on("sessions")
			.column("last_activity_at desc")
			.execute();

		// --- session_events (append-only transcript log) ---
		await db.schema
			.createTable("session_events")
			.ifNotExists()
			.addColumn("session_id", "text", (c) => c.notNull())
			.addColumn("seq", "integer", (c) => c.notNull())
			.addColumn("role", "text", (c) => c.notNull())
			.addColumn("kind", "text", (c) => c.notNull())
			.addColumn("payload", "text", (c) => c.notNull())
			.addColumn("created_at", "text", (c) => c.notNull())
			// (session_id, seq) is the primary key: it both enforces the monotonic
			// cursor and lets the tail query `WHERE session_id=? AND seq>?` seek the
			// index instead of scanning — the Turso row-read lesson from web/.
			.addPrimaryKeyConstraint("session_events_pk", ["session_id", "seq"])
			.execute();
	},
};

export const MIGRATIONS: Migration[] = [baseline];
