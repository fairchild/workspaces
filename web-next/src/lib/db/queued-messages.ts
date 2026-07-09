/*
 * Durable steering queue for mid-turn sends. Queued rows are intentionally not
 * transcript events: the ingest loop remains the single writer to
 * session_events, and claiming a row is the moment it becomes the next turn's
 * normal user event through startTurn.
 */
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import type { DatabaseHandle, QueuedMessagesTable } from "./client";
import { ensureSchema } from "./schema";

export interface QueuedMessage {
	sessionId: string;
	queueId: string;
	text: string;
	queuedAt: string;
	dispatchedAt: string | null;
	canceledAt: string | null;
	position: number;
}

export type CancelQueuedMessageResult = "canceled" | "not_found" | "dispatched";

const queueBus = new EventEmitter();
queueBus.setMaxListeners(0);

function isSqliteBusy(error: unknown): boolean {
	if (!(error instanceof Error)) return false;
	const code = "code" in error ? error.code : undefined;
	return error.message.includes("SQLITE_BUSY") || code === "SQLITE_BUSY";
}

async function sleep(ms: number): Promise<void> {
	await new Promise((resolve) => setTimeout(resolve, ms));
}

async function withBusyRetry<T>(operation: () => Promise<T>): Promise<T> {
	let lastError: unknown;
	for (let attempt = 0; attempt < 6; attempt += 1) {
		try {
			return await operation();
		} catch (error) {
			if (!isSqliteBusy(error)) throw error;
			lastError = error;
			await sleep(25 * 2 ** attempt);
		}
	}
	throw lastError;
}

export function notifyQueueChanged(sessionId: string): void {
	queueBus.emit(sessionId);
}

export function subscribeQueueChanged(
	sessionId: string,
	onChange: () => void,
): () => void {
	queueBus.on(sessionId, onChange);
	return () => queueBus.off(sessionId, onChange);
}

function rowToQueuedMessage(
	row: QueuedMessagesTable,
	position: number,
): QueuedMessage {
	return {
		sessionId: row.session_id,
		queueId: row.queue_id,
		text: row.text,
		queuedAt: row.queued_at,
		dispatchedAt: row.dispatched_at,
		canceledAt: row.canceled_at,
		position,
	};
}

export async function enqueueMessage(
	handle: DatabaseHandle,
	sessionId: string,
	text: string,
): Promise<QueuedMessage> {
	await ensureSchema(handle);
	const row: QueuedMessagesTable = {
		session_id: sessionId,
		queue_id: randomUUID(),
		text,
		queued_at: new Date().toISOString(),
		dispatched_at: null,
		canceled_at: null,
	};
	await withBusyRetry(() =>
		handle.db.insertInto("queued_messages").values(row).execute(),
	);
	const active = await listQueuedMessages(handle, sessionId);
	notifyQueueChanged(sessionId);
	return (
		active.find((message) => message.queueId === row.queue_id) ??
		rowToQueuedMessage(row, active.length)
	);
}

export async function listQueuedMessages(
	handle: DatabaseHandle,
	sessionId: string,
): Promise<QueuedMessage[]> {
	await ensureSchema(handle);
	const rows = await withBusyRetry(() =>
		handle.db
			.selectFrom("queued_messages")
			.selectAll()
			.where("session_id", "=", sessionId)
			.where("dispatched_at", "is", null)
			.where("canceled_at", "is", null)
			.orderBy("queued_at", "asc")
			.orderBy("queue_id", "asc")
			.execute(),
	);
	return rows.map((row, index) => rowToQueuedMessage(row, index + 1));
}

export async function claimNextQueuedMessage(
	handle: DatabaseHandle,
	sessionId: string,
): Promise<QueuedMessage | null> {
	await ensureSchema(handle);
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const row = await withBusyRetry(() =>
			handle.db
				.selectFrom("queued_messages")
				.selectAll()
				.where("session_id", "=", sessionId)
				.where("dispatched_at", "is", null)
				.where("canceled_at", "is", null)
				.orderBy("queued_at", "asc")
				.orderBy("queue_id", "asc")
				.limit(1)
				.executeTakeFirst(),
		);
		if (!row) return null;

		const dispatchedAt = new Date().toISOString();
		const result = await withBusyRetry(() =>
			handle.db
				.updateTable("queued_messages")
				.set({ dispatched_at: dispatchedAt })
				.where("session_id", "=", sessionId)
				.where("queue_id", "=", row.queue_id)
				.where("dispatched_at", "is", null)
				.where("canceled_at", "is", null)
				.execute(),
		);
		if (Number(result[0]?.numUpdatedRows ?? 0) === 0) continue;
		notifyQueueChanged(sessionId);
		return rowToQueuedMessage({ ...row, dispatched_at: dispatchedAt }, 1);
	}
	return null;
}

export async function releaseClaimedQueuedMessage(
	handle: DatabaseHandle,
	message: Pick<QueuedMessage, "sessionId" | "queueId">,
): Promise<void> {
	await ensureSchema(handle);
	await withBusyRetry(() =>
		handle.db
			.updateTable("queued_messages")
			.set({ dispatched_at: null })
			.where("session_id", "=", message.sessionId)
			.where("queue_id", "=", message.queueId)
			.where("canceled_at", "is", null)
			.execute(),
	);
	notifyQueueChanged(message.sessionId);
}

export async function cancelQueuedMessage(
	handle: DatabaseHandle,
	sessionId: string,
	queueId: string,
): Promise<CancelQueuedMessageResult> {
	await ensureSchema(handle);
	const canceledAt = new Date().toISOString();
	const result = await withBusyRetry(() =>
		handle.db
			.updateTable("queued_messages")
			.set({ canceled_at: canceledAt })
			.where("session_id", "=", sessionId)
			.where("queue_id", "=", queueId)
			.where("dispatched_at", "is", null)
			.where("canceled_at", "is", null)
			.execute(),
	);
	if (Number(result[0]?.numUpdatedRows ?? 0) > 0) {
		notifyQueueChanged(sessionId);
		return "canceled";
	}
	const row = await withBusyRetry(() =>
		handle.db
			.selectFrom("queued_messages")
			.select(["dispatched_at", "canceled_at"])
			.where("session_id", "=", sessionId)
			.where("queue_id", "=", queueId)
			.executeTakeFirst(),
	);
	if (!row || row.canceled_at) return "not_found";
	return row.dispatched_at ? "dispatched" : "not_found";
}
