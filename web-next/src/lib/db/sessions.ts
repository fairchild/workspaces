/*
 * Persistence for sessions and their append-only event log. Writes provider
 * StreamChunks into `session_events` (assigning the per-session monotonic seq),
 * reads them back in order, and projects them to a UIMessage transcript via the
 * pure projection in ../transcript/project-events.
 *
 * Payload shape: events are stored provider-native (StreamChunk-shaped), with
 * the adapter run at read time. Rationale in web-next/docs/schema.md — keeping
 * the raw log as the source of truth lets projection improve across adapter
 * versions and keeps #749's ingest a dumb append.
 */
import type { StreamChunk } from "../agent-runtime/stream-chunk";
import type {
	ProjectedEvent,
	SessionEventRole,
} from "../transcript/project-events";
import { projectSessionEvents } from "../transcript/project-events";
import type { DatabaseHandle, SessionsTable } from "./client";
import { ensureSchema } from "./schema";

export interface NewSession {
	id: string;
	repoId?: string | null;
	title?: string;
	provider: string;
	status?: string;
	claudeSessionId?: string | null;
}

export interface Session {
	id: string;
	repoId: string | null;
	title: string;
	provider: string;
	status: string;
	claudeSessionId: string | null;
	createdAt: string;
	lastActivityAt: string;
}

/** An event to append: a StreamChunk plus whose turn it belongs to. */
export interface AppendEvent {
	role: SessionEventRole;
	chunk: StreamChunk;
}

function rowToSession(row: SessionsTable): Session {
	return {
		id: row.id,
		repoId: row.repo_id,
		title: row.title,
		provider: row.provider,
		status: row.status,
		claudeSessionId: row.claude_session_id,
		createdAt: row.created_at,
		lastActivityAt: row.last_activity_at,
	};
}

export async function createSession(
	handle: DatabaseHandle,
	session: NewSession,
): Promise<Session> {
	await ensureSchema(handle);
	const now = new Date().toISOString();
	const row: SessionsTable = {
		id: session.id,
		repo_id: session.repoId ?? null,
		title: session.title ?? "",
		provider: session.provider,
		status: session.status ?? "active",
		claude_session_id: session.claudeSessionId ?? null,
		created_at: now,
		last_activity_at: now,
	};
	await handle.db.insertInto("sessions").values(row).execute();
	return rowToSession(row);
}

/** A sessions-home row: the session plus its repo's display name. */
export interface SessionListItem extends Session {
	repoFullName: string | null;
}

/**
 * Sessions for the home screen, most recently active first (served by the
 * `idx_sessions_last_activity` index).
 */
export async function listSessions(
	handle: DatabaseHandle,
	limit = 100,
): Promise<SessionListItem[]> {
	await ensureSchema(handle);
	const rows = await handle.db
		.selectFrom("sessions")
		.leftJoin("repos", "repos.id", "sessions.repo_id")
		.selectAll("sessions")
		.select("repos.full_name as repo_full_name")
		.orderBy("sessions.last_activity_at", "desc")
		.limit(limit)
		.execute();
	return rows.map((row) => ({
		...rowToSession(row),
		repoFullName: row.repo_full_name,
	}));
}

export async function getSession(
	handle: DatabaseHandle,
	id: string,
): Promise<Session | undefined> {
	await ensureSchema(handle);
	const row = await handle.db
		.selectFrom("sessions")
		.selectAll()
		.where("id", "=", id)
		.executeTakeFirst();
	return row ? rowToSession(row) : undefined;
}

/**
 * Appends events to a session's log, assigning each the next monotonic seq.
 * Runs in a transaction so the read-max-then-insert is atomic (single-writer in
 * production; the transaction keeps tests and any overlap correct). Returns the
 * seq assigned to the last event — the cursor a tail reader would resume from.
 */
export async function appendEvents(
	handle: DatabaseHandle,
	sessionId: string,
	events: readonly AppendEvent[],
): Promise<number> {
	await ensureSchema(handle);
	if (events.length === 0) {
		return currentMaxSeq(handle, sessionId);
	}
	const now = new Date().toISOString();
	return handle.db.transaction().execute(async (trx) => {
		const max = await trx
			.selectFrom("session_events")
			.select(({ fn }) => fn.max("seq").as("maxSeq"))
			.where("session_id", "=", sessionId)
			.executeTakeFirst();
		let seq = Number(max?.maxSeq ?? 0);
		for (const event of events) {
			seq += 1;
			await trx
				.insertInto("session_events")
				.values({
					session_id: sessionId,
					seq,
					role: event.role,
					kind: event.chunk.type,
					payload: JSON.stringify(event.chunk),
					created_at: now,
				})
				.execute();
		}
		await trx
			.updateTable("sessions")
			.set({ last_activity_at: now })
			.where("id", "=", sessionId)
			.execute();
		return seq;
	});
}

async function currentMaxSeq(
	handle: DatabaseHandle,
	sessionId: string,
): Promise<number> {
	const max = await handle.db
		.selectFrom("session_events")
		.select(({ fn }) => fn.max("seq").as("maxSeq"))
		.where("session_id", "=", sessionId)
		.executeTakeFirst();
	return Number(max?.maxSeq ?? 0);
}

/**
 * Reads a session's events in seq order, optionally only those after `sinceSeq`
 * (the resume path — the composite PK makes this an index seek, not a scan).
 */
export async function readEvents(
	handle: DatabaseHandle,
	sessionId: string,
	sinceSeq = 0,
): Promise<ProjectedEvent[]> {
	await ensureSchema(handle);
	const rows = await handle.db
		.selectFrom("session_events")
		.select(["seq", "role", "payload"])
		.where("session_id", "=", sessionId)
		.where("seq", ">", sinceSeq)
		.orderBy("seq", "asc")
		.execute();
	return rows.map((row) => ({
		seq: row.seq,
		role: row.role as SessionEventRole,
		chunk: JSON.parse(row.payload) as StreamChunk,
	}));
}

/** Convenience: read a session's full log and project it to a transcript. */
export async function readTranscript(
	handle: DatabaseHandle,
	sessionId: string,
): Promise<Awaited<ReturnType<typeof projectSessionEvents>>> {
	const events = await readEvents(handle, sessionId);
	return projectSessionEvents(sessionId, events);
}
