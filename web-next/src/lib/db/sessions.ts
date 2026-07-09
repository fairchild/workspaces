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
import { sql } from "kysely";
import { DEFAULT_MODEL } from "../agent-runtime/models";
import type { ApprovalPolicy } from "../agent-runtime/approval-policy";
import type { StreamChunk } from "../agent-runtime/stream-chunk";
import type {
	ProjectedEvent,
	SessionEventRole,
} from "../transcript/project-events";
import { projectSessionEvents } from "../transcript/project-events";
import type { DatabaseHandle, SessionsTable } from "./client";
import { ensureSchema } from "./schema";

const SESSION_STATUSES = ["active", "idle", "archived"] as const;

export type SessionStatus = (typeof SESSION_STATUSES)[number];

export interface NewSession {
	id: string;
	repoId?: string | null;
	/** Acting GitHub login; omitted only for legacy/test rows. */
	ownerLogin?: string | null;
	title?: string;
	provider: string;
	status?: string;
	claudeSessionId?: string | null;
	/** Claude model id to stamp; defaults to `DEFAULT_MODEL` when omitted. */
	model?: string;
	/** Approval policy; defaults to auto for the sandbox-first web path. */
	approvalPolicy?: ApprovalPolicy;
}

export interface Session {
	id: string;
	repoId: string | null;
	/** GitHub login that created the session; null for legacy grandfathered rows. */
	ownerLogin: string | null;
	title: string;
	firstUserMessage: string | null;
	provider: string;
	status: string;
	claudeSessionId: string | null;
	/** JSON harness resume payload from the last turn's detach(), or null. */
	resumeState: string | null;
	/** Claude model id this session's turns run on (#824). */
	model: string;
	/** Tool approval posture for this session's provider turns (#982). */
	approvalPolicy: ApprovalPolicy;
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
		ownerLogin: row.owner_login,
		title: row.title,
		firstUserMessage: row.first_user_message,
		provider: row.provider,
		status: row.status,
		claudeSessionId: row.claude_session_id,
		resumeState: row.resume_state,
		model: row.model,
		approvalPolicy: row.approval_policy,
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
		owner_login: session.ownerLogin?.trim().toLowerCase() || null,
		title: session.title ?? "",
		first_user_message: null,
		provider: session.provider,
		status: session.status ?? "active",
		claude_session_id: session.claudeSessionId ?? null,
		resume_state: null,
		model: session.model ?? DEFAULT_MODEL,
		approval_policy: session.approvalPolicy ?? "auto",
		created_at: now,
		last_activity_at: now,
	};
	await handle.db.insertInto("sessions").values(row).execute();
	return rowToSession(row);
}

/**
 * Persists the harness handle a turn parked with `detach()` (claude session id
 * + JSON resume payload; `resumeState` of `null` clears a stale handle),
 * the session's selected model (#824's picker), and/or a user-edited title
 * (#823 — unconditional, unlike `titleSessionIfEmpty` below: an explicit edit
 * always wins).
 */
export async function updateSession(
	handle: DatabaseHandle,
	id: string,
	fields: {
		claudeSessionId?: string | null;
		resumeState?: string | null;
		model?: string;
		title?: string;
		approvalPolicy?: ApprovalPolicy;
	},
): Promise<void> {
	await ensureSchema(handle);
	const set: Partial<SessionsTable> = {};
	if ("claudeSessionId" in fields) set.claude_session_id = fields.claudeSessionId ?? null;
	if ("resumeState" in fields) set.resume_state = fields.resumeState ?? null;
	if ("model" in fields && fields.model) set.model = fields.model;
	if ("title" in fields && fields.title) set.title = fields.title;
	if ("approvalPolicy" in fields && fields.approvalPolicy)
		set.approval_policy = fields.approvalPolicy;
	if (Object.keys(set).length === 0) return;
	await handle.db.updateTable("sessions").set(set).where("id", "=", id).execute();
}

/**
 * Titles a session ONLY if it has no title yet — the auto-titler's write
 * (#823). The empty-title check and the write share one atomic UPDATE
 * (`WHERE title = ''`), not a separate read-then-write, so two concurrent
 * first turns on the same session (the #811 race a `TurnConflictError` can't
 * always catch) can't both "win": SQLite serializes the two UPDATEs, the
 * first to commit clears the `title = ''` match, and the second is a no-op.
 * A blank `title` (the deriver's empty-message fallback) is also a no-op —
 * the session stays untitled for a later turn to name. Returns whether this
 * call was the one that set it.
 *
 * Known gap (codex review, #823): the guard makes the write race-safe (no
 * exception, no double-title, no lost update) but not race-*correct* in the
 * sense of always reflecting the log's true first user event — under the
 * same #811 double-first-send race, whichever caller's transaction commits
 * first wins the title, which is not guaranteed to be the caller holding the
 * lower `seq`. This is the same out-of-scope boundary #811 already draws
 * ("full serialization would need a DB reservation"); closing it fully means
 * deriving from a `SELECT ... ORDER BY seq LIMIT 1` read of the log rather
 * than the caller's local text, which folds into #811's eventual fix rather
 * than #823's.
 */
export async function titleSessionIfEmpty(
	handle: DatabaseHandle,
	id: string,
	title: string,
): Promise<boolean> {
	await ensureSchema(handle);
	if (!title) return false;
	const result = await handle.db
		.updateTable("sessions")
		.set({ title })
		.where("id", "=", id)
		.where("title", "=", "")
		.execute();
	return Number(result[0]?.numUpdatedRows ?? 0) > 0;
}

/**
 * Deletes a session and everything that hangs off it — its event log and any
 * terminal tickets — in one transaction, so a partial delete can't leave
 * orphaned events behind (the cascade the schema's PKs don't encode). Returns
 * whether a session row was actually removed. Sandbox teardown is the API
 * route's job (agent-runtime/sandbox-release.ts) — this is storage only.
 */
export async function deleteSession(
	handle: DatabaseHandle,
	id: string,
): Promise<boolean> {
	await ensureSchema(handle);
	return handle.db.transaction().execute(async (trx) => {
		await trx.deleteFrom("session_events").where("session_id", "=", id).execute();
		await trx.deleteFrom("queued_messages").where("session_id", "=", id).execute();
		await trx.deleteFrom("terminal_tickets").where("session_id", "=", id).execute();
		await trx.deleteFrom("turn_approvals").where("session_id", "=", id).execute();
		const result = await trx.deleteFrom("sessions").where("id", "=", id).execute();
		return Number(result[0]?.numDeletedRows ?? 0) > 0;
	});
}

/** A sessions-home row: the session plus its repo's display name. */
export interface SessionListItem extends Session {
	repoFullName: string | null;
}

export interface SessionListFilters {
	query?: string;
	repoId?: string;
	status?: string;
	limit?: number;
}

/**
 * Sessions for the home screen, most recently active first (served by the
 * `idx_sessions_last_activity` index).
 */
export async function listSessions(
	handle: DatabaseHandle,
	filtersOrLimit: SessionListFilters | number = {},
): Promise<SessionListItem[]> {
	await ensureSchema(handle);
	const filters =
		typeof filtersOrLimit === "number" ? { limit: filtersOrLimit } : filtersOrLimit;
	const query = filters.query?.trim();
	// Literal % and _ in a search must not act as LIKE wildcards.
	const likeQuery = query
		? `%${query.replace(/[\\%_]/g, (c) => `\\${c}`)}%`
		: undefined;
	let builder = handle.db
		.selectFrom("sessions")
		.leftJoin("repos", "repos.id", "sessions.repo_id")
		.selectAll("sessions")
		.select("repos.full_name as repo_full_name");

	if (likeQuery) {
		builder = builder.where((eb) =>
			eb.or([
				sql<boolean>`sessions.title like ${likeQuery} escape '\\'`,
				sql<boolean>`sessions.first_user_message like ${likeQuery} escape '\\'`,
			]),
		);
	}
	if (filters.repoId) {
		builder =
			filters.repoId === "__none"
				? builder.where("sessions.repo_id", "is", null)
				: builder.where("sessions.repo_id", "=", filters.repoId);
	}
	if (filters.status && SESSION_STATUSES.includes(filters.status as SessionStatus)) {
		builder = builder.where("sessions.status", "=", filters.status);
	}

	const rows = await builder
		.orderBy("sessions.last_activity_at", "desc")
		.limit(filters.limit ?? 100)
		.execute();
	return rows.map((row) => ({
		...rowToSession(row),
		repoFullName: row.repo_full_name,
	}));
}

export interface SessionListFilterOption {
	value: string;
	label: string;
	count: number;
}

export interface SessionListFilterOptions {
	repos: SessionListFilterOption[];
	statuses: SessionListFilterOption[];
}

/** Distinct repo/state facets for the sessions-home filters. */
export async function listSessionFilterOptions(
	handle: DatabaseHandle,
): Promise<SessionListFilterOptions> {
	await ensureSchema(handle);
	const [repoRows, statusRows] = await Promise.all([
		handle.db
			.selectFrom("sessions")
			.leftJoin("repos", "repos.id", "sessions.repo_id")
			.select(({ fn }) => [
				"sessions.repo_id as repo_id",
				"repos.full_name as repo_full_name",
				fn.countAll<number>().as("count"),
			])
			.groupBy(["sessions.repo_id", "repos.full_name"])
			.orderBy("repos.full_name", "asc")
			.execute(),
		handle.db
			.selectFrom("sessions")
			.select(({ fn }) => ["status", fn.countAll<number>().as("count")])
			.groupBy("status")
			.orderBy("status", "asc")
			.execute(),
	]);
	return {
		repos: repoRows.map((row) => ({
			value: row.repo_id ?? "__none",
			label: row.repo_full_name ?? "no repository",
			count: Number(row.count),
		})),
		statuses: statusRows.map((row) => ({
			value: row.status,
			label: row.status,
			count: Number(row.count),
		})),
	};
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
		const firstUserMessage = firstUserMessageFrom(events);
		if (firstUserMessage) {
			await trx
				.updateTable("sessions")
				.set({ first_user_message: firstUserMessage })
				.where("id", "=", sessionId)
				.where(sql<boolean>`first_user_message is null`)
				.execute();
		}
		return seq;
	});
}

/** In-process closers run one at a time: the local sqlite driver throws
 * SQLITE_BUSY on overlapping write transactions instead of queueing them, so
 * same-process concurrency is serialized here. Cross-instance concurrency is
 * covered by the transaction itself (Turso serializes writers server-side). */
let closeChain: Promise<unknown> = Promise.resolve();

/**
 * Appends `events` to the turn opening at `fromSeq` ONLY if that run has no
 * `done` yet — the check and the append share one transaction, so concurrent
 * closers (two resume GETs both classifying a turn stale) produce exactly one
 * terminal pair instead of duplicates: the winner closes, losers re-check and
 * see its `done`. Returns true when this call closed it.
 */
export async function appendEventsIfTurnOpen(
	handle: DatabaseHandle,
	sessionId: string,
	fromSeq: number,
	events: readonly AppendEvent[],
): Promise<boolean> {
	await ensureSchema(handle);
	const run = closeChain.then(() =>
		appendIfOpenOnce(handle, sessionId, fromSeq, events),
	);
	closeChain = run.catch(() => {});
	return run;
}

async function appendIfOpenOnce(
	handle: DatabaseHandle,
	sessionId: string,
	fromSeq: number,
	events: readonly AppendEvent[],
): Promise<boolean> {
	const now = new Date().toISOString();
	return handle.db.transaction().execute(async (trx) => {
		const closed = await trx
			.selectFrom("session_events")
			.select("seq")
			.where("session_id", "=", sessionId)
			.where("seq", ">=", fromSeq)
			.where("role", "=", "assistant")
			.where("kind", "=", "done")
			.limit(1)
			.executeTakeFirst();
		if (closed) return false;
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
		const firstUserMessage = firstUserMessageFrom(events);
		if (firstUserMessage) {
			await trx
				.updateTable("sessions")
				.set({ first_user_message: firstUserMessage })
				.where("id", "=", sessionId)
				.where(sql<boolean>`first_user_message is null`)
				.execute();
		}
		return true;
	});
}

function firstUserMessageFrom(events: readonly AppendEvent[]): string | null {
	for (const event of events) {
		if (event.role !== "user" || event.chunk.type !== "text") continue;
		const content = event.chunk.content.trim();
		if (content) return content;
	}
	return null;
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

/**
 * The `created_at` of a session's most recent event, or undefined if it has
 * none. The tail route uses it as a liveness clock: an "active" turn whose
 * newest event is older than the stale threshold is treated as abandoned (its
 * runner died) rather than left hanging the client.
 */
export async function newestEventAt(
	handle: DatabaseHandle,
	sessionId: string,
): Promise<string | undefined> {
	await ensureSchema(handle);
	const row = await handle.db
		.selectFrom("session_events")
		.select("created_at")
		.where("session_id", "=", sessionId)
		.orderBy("seq", "desc")
		.limit(1)
		.executeTakeFirst();
	return row?.created_at;
}

/** Convenience: read a session's full log and project it to a transcript. */
export async function readTranscript(
	handle: DatabaseHandle,
	sessionId: string,
): Promise<Awaited<ReturnType<typeof projectSessionEvents>>> {
	const events = await readEvents(handle, sessionId);
	return projectSessionEvents(sessionId, events);
}
