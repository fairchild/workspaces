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

interface Database {
	webhook_events: EventsTable;
	chat_messages: ChatMessagesTable;
	workspaces: WorkspacesTable;
}

let _turso: Client | undefined;
let _dialect: LibsqlDialect | undefined;
let _db: Kysely<Database> | undefined;

export function getTurso(): Client {
	if (!_turso) {
		const url = process.env.TURSO_DATABASE_URL ?? "file:data/auth.db";
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
