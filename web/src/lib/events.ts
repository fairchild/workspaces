import { getDb } from "./db";
import type { WebhookEvent, WebhookEventType } from "./types";

let migrated = false;

async function ensureEventsTable(): Promise<void> {
	if (migrated) return;
	const db = getDb();
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

export async function pushEvent(event: WebhookEvent): Promise<void> {
	await ensureEventsTable();
	const db = getDb();
	await db
		.insertInto("webhook_events")
		.values({
			id: event.id,
			type: event.type,
			action: event.action,
			summary: event.summary,
			repo: event.repo,
			timestamp: event.timestamp,
		})
		.onConflict((oc) => oc.doNothing())
		.execute();
}

export async function getEvents(
	limit = 50,
	repo?: string | null,
): Promise<WebhookEvent[]> {
	await ensureEventsTable();
	const db = getDb();
	let query = db
		.selectFrom("webhook_events")
		.selectAll()
		.orderBy("timestamp", "desc")
		.limit(limit);
	if (repo) {
		query = query.where("repo", "=", repo);
	}
	const rows = await query.execute();
	return rows.map((r) => ({
		id: r.id,
		type: r.type as WebhookEventType,
		action: r.action,
		summary: r.summary,
		repo: r.repo,
		timestamp: r.timestamp,
	}));
}

export async function getLastEventTime(repo: string): Promise<string | null> {
	await ensureEventsTable();
	const db = getDb();
	const row = await db
		.selectFrom("webhook_events")
		.select("timestamp")
		.where("repo", "=", repo)
		.orderBy("timestamp", "desc")
		.limit(1)
		.executeTakeFirst();
	return row?.timestamp ?? null;
}

export interface EventStats {
	eventsToday: number;
	repos: string[];
}

export async function getEventStats(): Promise<EventStats> {
	await ensureEventsTable();
	const db = getDb();
	const today = new Date();
	today.setHours(0, 0, 0, 0);
	const todayISO = today.toISOString();

	const [countResult, repoResult] = await Promise.all([
		db
			.selectFrom("webhook_events")
			.select(db.fn.countAll().as("count"))
			.where("timestamp", ">=", todayISO)
			.executeTakeFirstOrThrow(),
		db.selectFrom("webhook_events").select("repo").distinct().execute(),
	]);

	return {
		eventsToday: Number(countResult.count),
		repos: repoResult.map((r) => r.repo),
	};
}
