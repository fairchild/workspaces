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
		.addColumn("payload", "text", (c) => c.notNull().defaultTo("{}"))
		.execute();
	// Ensure payload column exists on tables created before this migration
	try {
		await db.schema
			.alterTable("webhook_events")
			.addColumn("payload", "text", (c) => c.notNull().defaultTo("{}"))
			.execute();
	} catch {
		/* column already exists */
	}
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
	// Composite index for `WHERE repo = ? ORDER BY timestamp DESC LIMIT N`.
	// Without this, that query scans every event for the repo — the chat
	// panel and activity feed poll endpoints hit this path every 5-10s
	// and blew through 500M Turso row-reads in a single month for one
	// user. The separate single-column indexes above are not enough; the
	// planner needs a composite that matches the filter + order.
	// See docs/development/agent-chat-sandbox.md § "DB query volume".
	await db.schema
		.createIndex("idx_webhook_events_repo_ts")
		.ifNotExists()
		.on("webhook_events")
		.columns(["repo", "timestamp desc"])
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
			payload: event.payload ?? "{}",
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
		.select(["id", "type", "action", "summary", "repo", "timestamp"])
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

export async function getEvent(id: string): Promise<WebhookEvent | null> {
	await ensureEventsTable();
	const db = getDb();
	const row = await db
		.selectFrom("webhook_events")
		.selectAll()
		.where("id", "=", id)
		.executeTakeFirst();
	if (!row) return null;
	return {
		id: row.id,
		type: row.type as WebhookEventType,
		action: row.action,
		summary: row.summary,
		repo: row.repo,
		timestamp: row.timestamp,
		payload: row.payload,
	};
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

/**
 * In-memory TTL cache for getEventStats. The "repos" list is a
 * SELECT DISTINCT full-table scan and the "eventsToday" count is a
 * range scan. Neither changes fast enough to justify running per
 * chat POST. 60s is plenty fresh for a stats card.
 *
 * Module-level cache survives across requests within the same warm
 * serverless function instance. Cold starts re-populate.
 */
const EVENT_STATS_TTL_MS = 60_000;
let cachedEventStats: { at: number; value: EventStats } | undefined;

export async function getEventStats(): Promise<EventStats> {
	const now = Date.now();
	if (cachedEventStats && now - cachedEventStats.at < EVENT_STATS_TTL_MS) {
		return cachedEventStats.value;
	}

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

	const value: EventStats = {
		eventsToday: Number(countResult.count),
		repos: repoResult.map((r) => r.repo),
	};
	cachedEventStats = { at: now, value };
	return value;
}

/** Exposed for tests — reset the TTL cache between runs. */
export function __resetEventStatsCache(): void {
	cachedEventStats = undefined;
}
