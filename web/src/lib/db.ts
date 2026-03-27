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

interface Database {
	webhook_events: EventsTable;
	chat_messages: ChatMessagesTable;
}

let _turso: Client | undefined;
let _dialect: LibsqlDialect | undefined;
let _db: Kysely<Database> | undefined;

export function getTurso(): Client {
	if (!_turso) {
		_turso = createClient({
			url: process.env.TURSO_DATABASE_URL ?? "file:data/auth.db",
			authToken: process.env.TURSO_AUTH_TOKEN,
		});
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
