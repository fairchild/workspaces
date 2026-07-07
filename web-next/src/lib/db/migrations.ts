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
import { type Kysely, sql } from "kysely";
import { DEFAULT_MODEL } from "../agent-runtime/models";
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

/**
 * Better Auth tables (real GitHub OAuth mode), in Better Auth's default
 * sqlite shape — camelCase columns, table names `user`/`session`/`account`/
 * `verification` — plus `githubLogin`, which the provider persists at
 * sign-in and the allowlist checks. Queried by Better Auth's own adapter,
 * so they are deliberately absent from the Kysely `Database` type.
 */
const authTables: Migration = {
	id: "0002_auth_tables",
	async up(db) {
		await sql`CREATE TABLE IF NOT EXISTS "user" (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			email TEXT NOT NULL UNIQUE,
			emailVerified INTEGER NOT NULL DEFAULT 0,
			image TEXT,
			githubLogin TEXT,
			createdAt TEXT NOT NULL DEFAULT (datetime('now')),
			updatedAt TEXT NOT NULL DEFAULT (datetime('now'))
		)`.execute(db);

		await sql`CREATE TABLE IF NOT EXISTS session (
			id TEXT PRIMARY KEY,
			expiresAt TEXT NOT NULL,
			token TEXT NOT NULL UNIQUE,
			createdAt TEXT NOT NULL DEFAULT (datetime('now')),
			updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
			ipAddress TEXT,
			userAgent TEXT,
			userId TEXT NOT NULL,
			FOREIGN KEY (userId) REFERENCES "user"(id) ON DELETE CASCADE
		)`.execute(db);
		await sql`CREATE INDEX IF NOT EXISTS idx_session_userId ON session(userId)`.execute(
			db,
		);

		await sql`CREATE TABLE IF NOT EXISTS account (
			id TEXT PRIMARY KEY,
			accountId TEXT NOT NULL,
			providerId TEXT NOT NULL,
			userId TEXT NOT NULL,
			accessToken TEXT,
			refreshToken TEXT,
			idToken TEXT,
			accessTokenExpiresAt TEXT,
			refreshTokenExpiresAt TEXT,
			scope TEXT,
			password TEXT,
			createdAt TEXT NOT NULL DEFAULT (datetime('now')),
			updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
			FOREIGN KEY (userId) REFERENCES "user"(id) ON DELETE CASCADE
		)`.execute(db);
		await sql`CREATE INDEX IF NOT EXISTS idx_account_userId ON account(userId)`.execute(
			db,
		);

		await sql`CREATE TABLE IF NOT EXISTS verification (
			id TEXT PRIMARY KEY,
			identifier TEXT NOT NULL,
			value TEXT NOT NULL,
			expiresAt TEXT NOT NULL,
			createdAt TEXT NOT NULL DEFAULT (datetime('now')),
			updatedAt TEXT NOT NULL DEFAULT (datetime('now'))
		)`.execute(db);
		await sql`CREATE INDEX IF NOT EXISTS idx_verification_identifier ON verification(identifier)`.execute(
			db,
		);
	},
};

/**
 * Adds `sessions.resume_state` — the JSON harness resume payload a turn parks
 * with `detach()` so the next turn reconnects the same session (#826/#750).
 * Idempotent via a column probe: SQLite `ALTER TABLE ADD COLUMN` has no
 * `IF NOT EXISTS`, and a partial run must re-apply cleanly.
 */
const sessionResumeState: Migration = {
	id: "0003_session_resume_state",
	async up(db) {
		const info = await sql<{
			name: string;
		}>`PRAGMA table_info(sessions)`.execute(db);
		const hasColumn = info.rows.some((row) => row.name === "resume_state");
		if (!hasColumn) {
			await db.schema
				.alterTable("sessions")
				.addColumn("resume_state", "text")
				.execute();
		}
	},
};

/**
 * Adds `sessions.model` — the Claude model this session's turns run on
 * (#824). Defaults existing and new rows to `DEFAULT_MODEL` (the current best
 * model per `agent-runtime/models.ts`) via a SQL constant default, so the
 * backfill for pre-existing sessions and the default for new ones are the
 * same value without a second write. Idempotent via the same column-probe
 * pattern as `0003_session_resume_state`.
 */
const sessionModel: Migration = {
	id: "0004_session_model",
	async up(db) {
		const info = await sql<{
			name: string;
		}>`PRAGMA table_info(sessions)`.execute(db);
		const hasColumn = info.rows.some((row) => row.name === "model");
		if (!hasColumn) {
			await db.schema
				.alterTable("sessions")
				.addColumn("model", "text", (col) => col.notNull().defaultTo(DEFAULT_MODEL))
				.execute();
		}
	},
};

/**
 * Adds `terminal_tickets` — single-use, short-TTL terminal access tickets
 * (#752, the ticket/HMAC model ported from web/'s terminal_access_tickets).
 * Rows are pruned opportunistically on issue; no index beyond the PK is
 * needed at this volume (one user, seconds-long TTLs).
 */
const terminalTickets: Migration = {
	id: "0005_terminal_tickets",
	async up(db) {
		await db.schema
			.createTable("terminal_tickets")
			.ifNotExists()
			.addColumn("ticket_hash", "text", (c) => c.primaryKey())
			.addColumn("login", "text", (c) => c.notNull())
			.addColumn("session_id", "text", (c) => c.notNull())
			.addColumn("mode", "text", (c) => c.notNull())
			.addColumn("sandbox_name", "text")
			.addColumn("created_at", "text", (c) => c.notNull())
			.addColumn("expires_at", "text", (c) => c.notNull())
			.addColumn("redeemed_at", "text")
			.execute();
	},
};

export const MIGRATIONS: Migration[] = [
	baseline,
	authTables,
	sessionResumeState,
	sessionModel,
	terminalTickets,
];
