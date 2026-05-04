import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { type Client, createClient } from "@libsql/client";
import { Kysely } from "kysely";
import { LibsqlDialect } from "./libsql-dialect";

export interface EventsTable {
	id: string;
	type: string;
	action: string;
	summary: string;
	repo: string;
	timestamp: string;
	payload: string;
}

export interface ChatMessagesTable {
	id: string;
	repo: string;
	author: string;
	author_type: string;
	content: string;
	agent_target: string | null;
	discussion_id: string | null;
	discussion_url: string | null;
	timestamp: string;
}

export interface WorkspacesTable {
	owner_id: string | null;
	id: string;
	name: string;
	path: string;
	repo_id: string | null;
	repo_name: string | null;
	created_at: string;
	last_accessed_at: string;
	status: string;
	git_branch: string | null;
	backend_identifier: string;
	synced_at: string;
}

export interface AgentSessionsTable {
	id: string;
	user_id: string | null;
	repo: string;
	agent_name: string;
	compute_backend: string;
	compute_instance_id: string | null;
	snapshot_id: string | null;
	claude_session_id: string | null;
	thread_id: string;
	discussion_id: string | null;
	status: string;
	created_at: string;
	last_activity_at: string;
}

export interface BaseSnapshotsTable {
	provider: string;
	version: string;
	snapshot_id: string;
	created_at: string;
}

export interface ManagedAgentsCacheTable {
	kind: string;
	hash: string;
	remote_id: string;
	created_at: string;
	metadata: string | null;
}

interface Database {
	webhook_events: EventsTable;
	chat_messages: ChatMessagesTable;
	workspaces: WorkspacesTable;
	agent_sessions: AgentSessionsTable;
	base_snapshots: BaseSnapshotsTable;
	managed_agents_cache: ManagedAgentsCacheTable;
}

let _turso: Client | undefined;
let _dialect: LibsqlDialect | undefined;
let _db: Kysely<Database> | undefined;
let _authSchema: Promise<void> | undefined;

export function getDatabaseURL(
	env: Record<string, string | undefined> = process.env,
): string {
	if (env.TURSO_DATABASE_URL) return env.TURSO_DATABASE_URL;

	if (env.VERCEL_ENV === "production") {
		throw new Error("TURSO_DATABASE_URL is required in production");
	}

	if (env.VERCEL === "1" || env.VERCEL_ENV || env.VERCEL_URL) {
		return "file:/tmp/workspaces-auth.db";
	}

	return "file:data/auth.db";
}

export function getTurso(): Client {
	if (!_turso) {
		const url = getDatabaseURL();
		if (url.startsWith("file:")) {
			mkdirSync(dirname(url.slice(5)), { recursive: true });
		}
		_turso = createClient({ url, authToken: process.env.TURSO_AUTH_TOKEN });
	}
	return _turso;
}

export function getDialect(): LibsqlDialect {
	if (!_dialect) {
		_dialect = new LibsqlDialect({ client: getTurso() });
	}
	return _dialect;
}

export function getDb(): Kysely<Database> {
	if (!_db) {
		_db = new Kysely<Database>({ dialect: getDialect() });
	}
	return _db;
}

async function createAuthTables(): Promise<void> {
	const db = getTurso();
	await db.execute(`CREATE TABLE IF NOT EXISTS "user" (
		id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		email TEXT NOT NULL UNIQUE,
		emailVerified INTEGER NOT NULL DEFAULT 0,
		image TEXT,
		createdAt TEXT NOT NULL DEFAULT (datetime('now')),
		updatedAt TEXT NOT NULL DEFAULT (datetime('now'))
	)`);

	await db.execute(`CREATE TABLE IF NOT EXISTS session (
		id TEXT PRIMARY KEY,
		expiresAt TEXT NOT NULL,
		token TEXT NOT NULL UNIQUE,
		createdAt TEXT NOT NULL DEFAULT (datetime('now')),
		updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
		ipAddress TEXT,
		userAgent TEXT,
		userId TEXT NOT NULL,
		FOREIGN KEY (userId) REFERENCES "user"(id) ON DELETE CASCADE
	)`);
	await db.execute(
		"CREATE INDEX IF NOT EXISTS idx_session_userId ON session(userId)",
	);

	await db.execute(`CREATE TABLE IF NOT EXISTS account (
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
	)`);
	await db.execute(
		"CREATE INDEX IF NOT EXISTS idx_account_userId ON account(userId)",
	);

	await db.execute(`CREATE TABLE IF NOT EXISTS verification (
		id TEXT PRIMARY KEY,
		identifier TEXT NOT NULL,
		value TEXT NOT NULL,
		expiresAt TEXT NOT NULL,
		createdAt TEXT NOT NULL DEFAULT (datetime('now')),
		updatedAt TEXT NOT NULL DEFAULT (datetime('now'))
	)`);
	await db.execute(
		"CREATE INDEX IF NOT EXISTS idx_verification_identifier ON verification(identifier)",
	);
}

export function ensureAuthTables(): Promise<void> {
	_authSchema ??= createAuthTables().catch((error) => {
		_authSchema = undefined;
		throw error;
	});
	return _authSchema;
}
