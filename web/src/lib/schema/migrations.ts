/**
 * Schema definition for the web database.
 *
 * The schema is an ordered, append-only list of migrations (`MIGRATIONS`). Each has
 * a stable `id` and an idempotent `up(db)` that brings a database to the state that
 * migration describes. `ensureSchema()` (in ./index) runs the pending migrations in
 * order and records each `id` in the `schema_migrations` table. A concurrent cold
 * start may enter the same pending migration before another instance records it, so
 * `up` functions must stay idempotent and tolerate benign DDL races.
 *
 * Changing the schema:
 *  - Append a new migration with the next ordered id; never edit one that has
 *    shipped — it is already recorded and will not run again, so add a follow-up
 *    migration instead.
 *  - Keep `up` idempotent: `createTable().ifNotExists()`, `createIndex().ifNotExists()`,
 *    `addMissingColumns()` for added columns, and data writes guarded by a WHERE
 *    clause. The runner records a migration only after `up` resolves, so a failure
 *    partway through re-runs `up` from the top on the next call. A second cold-start
 *    runner can also overlap the first — `up` must tolerate both cases.
 *  - Add the table's row type to the `Database` interface in ../db for typed access.
 *    (Raw-libsql tables like `user_repos`/`terminal_access_tickets` are the exception;
 *    their DDL still lives here so all schema is in one place.)
 *
 * Design rationale and tradeoffs: web/docs/schema-management.md and
 * docs/decisions/web-schema-toolchain.md.
 */

import { type Kysely, sql } from "kysely";
import { type Database, getTurso } from "../db";

/** One tracked migration: a stable `id` and an idempotent `up`. */
export interface Migration {
	id: string;
	up(db: Kysely<Database>): Promise<void>;
}

interface MissingColumn {
	name: string;
	type: "text" | "integer";
	notNull?: boolean;
	defaultTo?: string;
}

/**
 * Add the listed columns that aren't already on `table`. Reads the live columns
 * (`PRAGMA table_info`) and adds only the missing ones, so a table that exists with
 * a narrower set of columns converges to the target shape — idempotent, with no
 * blind try/catch. Table names are internal constants, so interpolating into the
 * PRAGMA is safe.
 */
async function addMissingColumns(
	db: Kysely<Database>,
	table: string,
	columns: MissingColumn[],
): Promise<void> {
	const info = await getTurso().execute(`PRAGMA table_info("${table}")`);
	if (info.rows.length === 0) return; // fresh DB — createTable already built it in full
	const present = new Set(info.rows.map((r) => String(r.name)));
	for (const col of columns) {
		if (present.has(col.name)) continue;
		await db.schema
			.alterTable(table)
			.addColumn(col.name, col.type, (c) => {
				let built = c;
				if (col.notNull) built = built.notNull();
				if (col.defaultTo !== undefined) built = built.defaultTo(col.defaultTo);
				return built;
			})
			.execute()
			.catch((err: unknown) => {
				if (isDuplicateColumnError(err, col.name)) return;
				throw err;
			});
	}
}

function isDuplicateColumnError(err: unknown, column: string): boolean {
	const message = err instanceof Error ? err.message : String(err);
	return (
		message.toLowerCase().includes("duplicate column name") &&
		message.includes(column)
	);
}

/**
 * Baseline schema: every table, index, and data normalization the app needs.
 * Idempotent and reconciling — it creates missing tables, adds missing columns, and
 * normalizes data through guarded writes, converging any database (empty or partial)
 * to this schema without disturbing existing rows.
 */
const baseline: Migration = {
	id: "0001_baseline",
	async up(db) {
		// --- webhook_events ---
		await db.schema
			.createTable("webhook_events")
			.ifNotExists()
			.addColumn("id", "text", (c) => c.primaryKey())
			.addColumn("type", "text", (c) => c.notNull())
			.addColumn("action", "text", (c) => c.notNull().defaultTo(""))
			.addColumn("summary", "text", (c) => c.notNull().defaultTo(""))
			.addColumn("repo", "text", (c) => c.notNull().defaultTo("unknown"))
			.addColumn("timestamp", "text", (c) => c.notNull())
			.addColumn("payload", "text", (c) => c.notNull().defaultTo("{}"))
			.execute();
		await addMissingColumns(db, "webhook_events", [
			{ name: "payload", type: "text", notNull: true, defaultTo: "{}" },
		]);
		await db.schema
			.createIndex("idx_webhook_events_timestamp")
			.ifNotExists()
			.on("webhook_events")
			.column("timestamp desc")
			.execute();
		await db.schema
			.createIndex("idx_webhook_events_repo")
			.ifNotExists()
			.on("webhook_events")
			.column("repo")
			.execute();
		// Composite index for `WHERE repo = ? ORDER BY timestamp DESC LIMIT N`,
		// the chat/activity poll path. The single-column indexes are not enough.
		await db.schema
			.createIndex("idx_webhook_events_repo_ts")
			.ifNotExists()
			.on("webhook_events")
			.columns(["repo", "timestamp desc"])
			.execute();

		// --- chat_messages ---
		await db.schema
			.createTable("chat_messages")
			.ifNotExists()
			.addColumn("id", "text", (c) => c.primaryKey())
			.addColumn("repo", "text", (c) => c.notNull())
			.addColumn("author", "text", (c) => c.notNull())
			.addColumn("author_type", "text", (c) => c.notNull())
			.addColumn("content", "text", (c) => c.notNull())
			.addColumn("agent_target", "text")
			.addColumn("discussion_id", "text")
			.addColumn("discussion_url", "text")
			.addColumn("timestamp", "text", (c) => c.notNull())
			.execute();
		await db.schema
			.createIndex("idx_chat_messages_repo_ts")
			.ifNotExists()
			.on("chat_messages")
			.columns(["repo", "timestamp desc"])
			.execute();

		// --- agent_sessions ---
		await db.schema
			.createTable("agent_sessions")
			.ifNotExists()
			.addColumn("id", "text", (c) => c.primaryKey())
			.addColumn("user_id", "text", (c) => c.notNull())
			.addColumn("repo", "text", (c) => c.notNull())
			.addColumn("agent_name", "text", (c) => c.notNull())
			.addColumn("compute_backend", "text", (c) => c.notNull())
			.addColumn("compute_instance_id", "text")
			.addColumn("thread_id", "text", (c) => c.notNull())
			.addColumn("discussion_id", "text")
			.addColumn("status", "text", (c) => c.notNull())
			.addColumn("created_at", "text", (c) => c.notNull())
			.addColumn("last_activity_at", "text", (c) => c.notNull())
			.addColumn("snapshot_id", "text")
			.addColumn("claude_session_id", "text")
			.execute();
		await addMissingColumns(db, "agent_sessions", [
			{ name: "snapshot_id", type: "text" },
			{ name: "claude_session_id", type: "text" },
			{ name: "user_id", type: "text" },
		]);
		await db.schema
			.createIndex("idx_agent_sessions_thread")
			.ifNotExists()
			.on("agent_sessions")
			.columns(["repo", "agent_name", "thread_id"])
			.execute();
		await db.schema
			.createIndex("idx_agent_sessions_user_thread")
			.ifNotExists()
			.on("agent_sessions")
			.columns(["user_id", "repo", "agent_name", "thread_id"])
			.execute();
		// Synthetic terminal sessions use the canonical name "shell"; normalize any
		// rows that still hold the non-canonical "terminal".
		await db
			.updateTable("agent_sessions")
			.set({ agent_name: "shell" })
			.where("agent_name", "=", "terminal")
			.where("status", "in", ["active", "streaming", "snapshotted"])
			.execute();

		// --- workspaces ---
		await db.schema
			.createTable("workspaces")
			.ifNotExists()
			// Literal rather than importing DEFAULT_WORKSPACE_OWNER_ID, to keep
			// migrations free of app-module imports.
			.addColumn("owner_id", "text", (c) => c.notNull().defaultTo("default"))
			.addColumn("id", "text", (c) => c.primaryKey())
			.addColumn("name", "text", (c) => c.notNull())
			.addColumn("path", "text", (c) => c.notNull())
			.addColumn("repo_id", "text")
			.addColumn("repo_name", "text")
			.addColumn("created_at", "text", (c) => c.notNull())
			.addColumn("last_accessed_at", "text", (c) => c.notNull())
			.addColumn("status", "text", (c) => c.notNull().defaultTo("stopped"))
			.addColumn("git_branch", "text")
			.addColumn("backend_identifier", "text", (c) =>
				c.notNull().defaultTo("local"),
			)
			.addColumn("synced_at", "text", (c) => c.notNull())
			.execute();
		await addMissingColumns(db, "workspaces", [
			{ name: "owner_id", type: "text" },
		]);
		await db
			.updateTable("workspaces")
			.set({ owner_id: "default" })
			.where("owner_id", "is", null)
			.execute();
		await db.schema
			.createIndex("idx_workspaces_owner")
			.ifNotExists()
			.on("workspaces")
			.column("owner_id")
			.execute();

		// --- base_snapshots ---
		await db.schema
			.createTable("base_snapshots")
			.ifNotExists()
			.addColumn("provider", "text", (c) => c.notNull())
			.addColumn("version", "text", (c) => c.notNull())
			.addColumn("snapshot_id", "text", (c) => c.notNull())
			.addColumn("created_at", "text", (c) => c.notNull())
			.addPrimaryKeyConstraint("base_snapshots_pk", ["provider", "version"])
			.execute();

		// --- managed_agents_cache ---
		await db.schema
			.createTable("managed_agents_cache")
			.ifNotExists()
			.addColumn("kind", "text", (c) => c.notNull())
			.addColumn("hash", "text", (c) => c.notNull())
			.addColumn("remote_id", "text", (c) => c.notNull())
			.addColumn("created_at", "text", (c) => c.notNull())
			.addColumn("metadata", "text")
			.execute();
		await db.schema
			.createIndex("idx_managed_agents_cache_key")
			.ifNotExists()
			.on("managed_agents_cache")
			.columns(["kind", "hash"])
			.execute();

		// --- managed_pr_review_runs ---
		await db.schema
			.createTable("managed_pr_review_runs")
			.ifNotExists()
			.addColumn("fingerprint", "text", (c) => c.primaryKey())
			.addColumn("repo_full_name", "text", (c) => c.notNull())
			.addColumn("pr_number", "integer", (c) => c.notNull())
			.addColumn("head_sha", "text", (c) => c.notNull())
			.addColumn("trigger_kind", "text", (c) => c.notNull())
			.addColumn("trigger_source_id", "text", (c) => c.notNull())
			.addColumn("reviewer_config_hash", "text", (c) => c.notNull())
			.addColumn("session_id", "text")
			.addColumn("status", "text", (c) => c.notNull())
			.addColumn("created_at", "text", (c) => c.notNull())
			.addColumn("updated_at", "text", (c) => c.notNull())
			.addColumn("error", "text")
			.addColumn("failure_kind", "text")
			.addColumn("failure_message", "text")
			.addColumn("failure_retryable", "integer")
			.addColumn("failed_at", "text")
			.addColumn("projection_status", "text")
			.addColumn("projection_updated_at", "text")
			.addColumn("projection_error", "text")
			.addColumn("github_review_id", "text")
			.addColumn("review_intent_event", "text")
			.addColumn("review_intent_body", "text")
			.addColumn("review_intent_labels", "text")
			.addColumn("review_intent_recorded_at", "text")
			.addColumn("active_claim_key", "text")
			.addColumn("coalesced_head_sha", "text")
			.addColumn("coalesced_trigger_kind", "text")
			.addColumn("coalesced_trigger_source_id", "text")
			.addColumn("coalesced_at", "text")
			.execute();
		await addMissingColumns(db, "managed_pr_review_runs", [
			{ name: "failure_kind", type: "text" },
			{ name: "failure_message", type: "text" },
			{ name: "failure_retryable", type: "integer" },
			{ name: "failed_at", type: "text" },
			{ name: "projection_status", type: "text" },
			{ name: "projection_updated_at", type: "text" },
			{ name: "projection_error", type: "text" },
			{ name: "github_review_id", type: "text" },
			{ name: "review_intent_event", type: "text" },
			{ name: "review_intent_body", type: "text" },
			{ name: "review_intent_labels", type: "text" },
			{ name: "review_intent_recorded_at", type: "text" },
			{ name: "active_claim_key", type: "text" },
			{ name: "coalesced_head_sha", type: "text" },
			{ name: "coalesced_trigger_kind", type: "text" },
			{ name: "coalesced_trigger_source_id", type: "text" },
			{ name: "coalesced_at", type: "text" },
		]);
		await db.schema
			.createIndex("idx_managed_pr_review_runs_pr")
			.ifNotExists()
			.on("managed_pr_review_runs")
			.columns(["repo_full_name", "pr_number"])
			.execute();
		// active_claim_key is unique but nullable; SQLite permits many NULLs, so the
		// constraint binds only runs currently holding a claim. Idle/completed runs
		// (NULL) age out through the stale-started path.
		await db.schema
			.createIndex("ux_managed_pr_review_runs_active_claim")
			.ifNotExists()
			.on("managed_pr_review_runs")
			.column("active_claim_key")
			.unique()
			.execute();

		// --- managed_pr_review_projections ---
		await db.schema
			.createTable("managed_pr_review_projections")
			.ifNotExists()
			.addColumn("projection_id", "text", (c) => c.primaryKey())
			.addColumn("run_fingerprint", "text", (c) => c.notNull())
			.addColumn("projection_type", "text", (c) => c.notNull())
			.addColumn("projection_key", "text", (c) => c.notNull())
			.addColumn("desired_payload_hash", "text", (c) => c.notNull())
			.addColumn("desired_payload", "text", (c) => c.notNull())
			.addColumn("state", "text", (c) => c.notNull())
			.addColumn("attempts", "integer", (c) => c.notNull().defaultTo(0))
			.addColumn("last_attempted_at", "text")
			.addColumn("observed_external_id", "text")
			.addColumn("error_kind", "text")
			.addColumn("error_text", "text")
			.addColumn("created_at", "text", (c) => c.notNull())
			.addColumn("updated_at", "text", (c) => c.notNull())
			.execute();
		await db.schema
			.createIndex("ux_managed_pr_review_projections_desired")
			.ifNotExists()
			.on("managed_pr_review_projections")
			.columns([
				"run_fingerprint",
				"projection_type",
				"projection_key",
				"desired_payload_hash",
			])
			.unique()
			.execute();
		await db.schema
			.createIndex("idx_managed_pr_review_projections_run")
			.ifNotExists()
			.on("managed_pr_review_projections")
			.column("run_fingerprint")
			.execute();
		await db.schema
			.createIndex("idx_managed_pr_review_projections_state")
			.ifNotExists()
			.on("managed_pr_review_projections")
			.columns(["state", "updated_at"])
			.execute();

		// --- terminal_access_tickets (queried via raw libsql in terminal-tickets.ts) ---
		await db.schema
			.createTable("terminal_access_tickets")
			.ifNotExists()
			.addColumn("ticket_hash", "text", (c) => c.primaryKey())
			.addColumn("user_id", "text", (c) => c.notNull())
			.addColumn("repo", "text", (c) => c.notNull())
			.addColumn("session_id", "text", (c) => c.notNull())
			.addColumn("compute_instance_id", "text", (c) => c.notNull())
			.addColumn("compute_backend", "text", (c) => c.notNull())
			.addColumn("created_at", "text", (c) => c.notNull())
			.addColumn("expires_at", "text", (c) => c.notNull())
			.addColumn("redeemed_at", "text")
			.execute();
		await db.schema
			.createIndex("idx_terminal_access_tickets_session")
			.ifNotExists()
			.on("terminal_access_tickets")
			.columns(["user_id", "repo", "session_id", "expires_at"])
			.execute();

		// --- user_repos (queried via raw libsql in repos.ts) ---
		await db.schema
			.createTable("user_repos")
			.ifNotExists()
			.addColumn("user_id", "text", (c) => c.notNull())
			.addColumn("owner", "text", (c) => c.notNull())
			.addColumn("repo", "text", (c) => c.notNull())
			.addColumn("added_at", "text", (c) =>
				c.notNull().defaultTo(sql`(datetime('now'))`),
			)
			.addPrimaryKeyConstraint("user_repos_pk", ["user_id", "owner", "repo"])
			.execute();
	},
};

const managedPrReviewRunSessionStartedAt: Migration = {
	id: "0002_managed_pr_review_run_session_started_at",
	async up(db) {
		await addMissingColumns(db, "managed_pr_review_runs", [
			{ name: "session_started_at", type: "text" },
		]);
	},
};

export const MIGRATIONS: Migration[] = [
	baseline,
	managedPrReviewRunSessionStartedAt,
];
