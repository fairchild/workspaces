import { db, ensureEventsTable } from "./db";
import type { WebhookEvent, WebhookEventType } from "./types";

export async function pushEvent(event: WebhookEvent): Promise<void> {
	await ensureEventsTable();
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

export async function getEvents(limit = 50): Promise<WebhookEvent[]> {
	await ensureEventsTable();
	const rows = await db
		.selectFrom("webhook_events")
		.selectAll()
		.orderBy("timestamp", "desc")
		.limit(limit)
		.execute();
	return rows.map((r) => ({
		id: r.id,
		type: r.type as WebhookEventType,
		action: r.action,
		summary: r.summary,
		repo: r.repo,
		timestamp: r.timestamp,
	}));
}

export interface EventStats {
	eventsToday: number;
	repos: string[];
}

export async function getEventStats(): Promise<EventStats> {
	await ensureEventsTable();
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
