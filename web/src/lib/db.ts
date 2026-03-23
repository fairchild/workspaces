import { createClient } from "@libsql/client";
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

interface Database {
	webhook_events: EventsTable;
}

export const turso = createClient({
	url: process.env.TURSO_DATABASE_URL ?? "file:data/auth.db",
	authToken: process.env.TURSO_AUTH_TOKEN,
});

export const dialect = new LibsqlDialect({ client: turso });

export const db = new Kysely<Database>({ dialect });

let migrated = false;

export async function ensureEventsTable(): Promise<void> {
	if (migrated) return;
	await db.schema
		.createTable("webhook_events")
		.ifNotExists()
		.addColumn("id", "text", (c) => c.primaryKey())
		.addColumn("type", "text", (c) => c.notNull())
		.addColumn("action", "text", (c) => c.notNull().defaultTo(""))
		.addColumn("summary", "text", (c) => c.notNull().defaultTo(""))
		.addColumn("repo", "text", (c) => c.notNull().defaultTo("unknown"))
		.addColumn("timestamp", "text", (c) => c.notNull())
		.execute();
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
	migrated = true;
}
