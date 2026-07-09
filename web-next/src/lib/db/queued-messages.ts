/*
 * Durable steering queue for mid-turn sends. Queued rows are intentionally not
 * transcript events while pending. Dispatch atomically marks the oldest row
 * claimed and appends its normal user event to session_events, so there is no
 * observable claimed-but-missing-from-the-log window.
 */
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { sql, type Insertable, type Selectable, type Transaction } from "kysely";
import type { Database, DatabaseHandle, QueuedMessagesTable } from "./client";
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

type QueuedMessageRow = Selectable<QueuedMessagesTable>;

export interface ClaimedQueuedTurn {
	queued: QueuedMessage;
	/** Seq of the user event appended in the same transaction as the claim. */
	userSeq: number;
	/** First assistant seq for the detached ingest/tail. */
	fromSeq: number;
}

export type ImmediateTurnStart =
	| {
			kind: "started";
			userSeq: number;
			fromSeq: number;
	  }
	| {
			kind: "queued";
			queued: QueuedMessage;
	  };

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

let queueStartChain: Promise<unknown> = Promise.resolve();

async function withSerializedQueueStart<T>(operation: () => Promise<T>): Promise<T> {
	const run = queueStartChain.then(() => withBusyRetry(operation));
	queueStartChain = run.catch(() => {});
	return run;
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
	row: QueuedMessageRow,
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
	const row: Insertable<QueuedMessagesTable> = {
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
	const inserted = active.find((message) => message.queueId === row.queue_id);
	if (!inserted) throw new Error("queued message insert was not readable");
	return inserted;
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
			.orderBy("id", "asc")
			.execute(),
	);
	return rows.map((row, index) => rowToQueuedMessage(row, index + 1));
}

/**
 * Opens a direct POST turn when the session log and queue are both idle;
 * otherwise enqueues the new text behind whatever is already running/pending.
 *
 * This is the direct-send half of the #984 serialization boundary. The
 * running-turn check, pending-queue check, and either user-event append or
 * queue insert share one transaction, so a queued continuation cannot race a
 * direct POST into reordering the session.
 */
export async function appendImmediateTurnOrQueue(
	handle: DatabaseHandle,
	sessionId: string,
	text: string,
): Promise<ImmediateTurnStart> {
	await ensureSchema(handle);
	const result = await withSerializedQueueStart(() =>
		handle.db.transaction().execute(async (trx) => {
			const hasOpen = await hasOpenTurn(trx, sessionId);
			const pendingCount = await countPendingMessages(trx, sessionId);
			if (hasOpen || pendingCount > 0) {
				const queued = await insertQueuedMessageInTransaction(
					trx,
					sessionId,
					text,
					pendingCount + 1,
				);
				return { kind: "queued" as const, queued };
			}
			const now = new Date().toISOString();
			const userSeq = await appendUserTextEventInTransaction(
				trx,
				sessionId,
				text,
				now,
			);
			return { kind: "started" as const, userSeq, fromSeq: userSeq + 1 };
		}),
	);
	if (result.kind === "queued") notifyQueueChanged(sessionId);
	return result;
}

/**
 * Atomically claims the oldest pending row and appends its user event.
 * Returning a result means the queue row is dispatched and visible in
 * session_events; returning null means no row was claimable because the session
 * had an open turn or an empty queue.
 */
export async function claimAndStartQueuedTurn(
	handle: DatabaseHandle,
	sessionId: string,
): Promise<ClaimedQueuedTurn | null> {
	await ensureSchema(handle);
	const claimed = await withSerializedQueueStart(() =>
		handle.db.transaction().execute(async (trx) => {
			const session = await trx
				.selectFrom("sessions")
				.select("id")
				.where("id", "=", sessionId)
				.executeTakeFirst();
			if (!session) return null;
			if (await hasOpenTurn(trx, sessionId)) return null;
			const row = await trx
				.selectFrom("queued_messages")
				.selectAll()
				.where("session_id", "=", sessionId)
				.where("dispatched_at", "is", null)
				.where("canceled_at", "is", null)
				.orderBy("id", "asc")
				.limit(1)
				.executeTakeFirst();
			if (!row) return null;

			const dispatchedAt = new Date().toISOString();
			const updated = await trx
				.updateTable("queued_messages")
				.set({ dispatched_at: dispatchedAt })
				.where("id", "=", row.id)
				.where("session_id", "=", sessionId)
				.where("dispatched_at", "is", null)
				.where("canceled_at", "is", null)
				.execute();
			if (Number(updated[0]?.numUpdatedRows ?? 0) === 0) return null;

			const userSeq = await appendUserTextEventInTransaction(
				trx,
				sessionId,
				row.text,
				dispatchedAt,
			);
			return {
				queued: rowToQueuedMessage({ ...row, dispatched_at: dispatchedAt }, 1),
				userSeq,
				fromSeq: userSeq + 1,
			};
		}),
	);
	if (claimed) notifyQueueChanged(sessionId);
	return claimed;
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

async function hasOpenTurn(
	trx: Transaction<Database>,
	sessionId: string,
): Promise<boolean> {
	const lastUser = await trx
		.selectFrom("session_events")
		.select("seq")
		.where("session_id", "=", sessionId)
		.where("role", "=", "user")
		.orderBy("seq", "desc")
		.limit(1)
		.executeTakeFirst();
	if (!lastUser) return false;
	const done = await trx
		.selectFrom("session_events")
		.select("seq")
		.where("session_id", "=", sessionId)
		.where("seq", ">=", lastUser.seq + 1)
		.where("role", "=", "assistant")
		.where("kind", "=", "done")
		.limit(1)
		.executeTakeFirst();
	return !done;
}

async function countPendingMessages(
	trx: Transaction<Database>,
	sessionId: string,
): Promise<number> {
	const count = await trx
		.selectFrom("queued_messages")
		.select(({ fn }) => fn.countAll().as("count"))
		.where("session_id", "=", sessionId)
		.where("dispatched_at", "is", null)
		.where("canceled_at", "is", null)
		.executeTakeFirst();
	return Number(count?.count ?? 0);
}

async function insertQueuedMessageInTransaction(
	trx: Transaction<Database>,
	sessionId: string,
	text: string,
	position: number,
): Promise<QueuedMessage> {
	const row: Insertable<QueuedMessagesTable> = {
		session_id: sessionId,
		queue_id: randomUUID(),
		text,
		queued_at: new Date().toISOString(),
		dispatched_at: null,
		canceled_at: null,
	};
	await trx.insertInto("queued_messages").values(row).execute();
	const inserted = await trx
		.selectFrom("queued_messages")
		.selectAll()
		.where("session_id", "=", sessionId)
		.where("queue_id", "=", row.queue_id)
		.executeTakeFirst();
	if (!inserted) throw new Error("queued message insert was not readable");
	return rowToQueuedMessage(inserted, position);
}

async function appendUserTextEventInTransaction(
	trx: Transaction<Database>,
	sessionId: string,
	text: string,
	now: string,
): Promise<number> {
	const max = await trx
		.selectFrom("session_events")
		.select(({ fn }) => fn.max("seq").as("maxSeq"))
		.where("session_id", "=", sessionId)
		.executeTakeFirst();
	const seq = Number(max?.maxSeq ?? 0) + 1;
	await trx
		.insertInto("session_events")
		.values({
			session_id: sessionId,
			seq,
			role: "user",
			kind: "text",
			payload: JSON.stringify({ type: "text", content: text }),
			created_at: now,
		})
		.execute();
	await trx
		.updateTable("sessions")
		.set({ last_activity_at: now })
		.where("id", "=", sessionId)
		.execute();
	const firstUserMessage = text.trim();
	if (firstUserMessage) {
		await trx
			.updateTable("sessions")
			.set({ first_user_message: firstUserMessage })
			.where("id", "=", sessionId)
			.where(sql<boolean>`first_user_message is null`)
			.execute();
	}
	return seq;
}
