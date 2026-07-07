/*
 * libSQL/Kysely wiring for web-next's durable session store. Defines the typed
 * `Database` schema (the row shapes Kysely checks queries against) and opens a
 * connection + query builder over @libsql/client. Tests open a throwaway
 * `file:` handle; the app uses a lazily-created singleton from the
 * env-configured URL.
 *
 * The schema itself is fresh (no legacy chat_messages compatibility); only the
 * connection pattern is ported from web/src/lib/db.ts.
 */
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { type Client, createClient } from "@libsql/client";
import { Kysely } from "kysely";
import { LibsqlDialect } from "./libsql-dialect";

/**
 * A connected repository (a GitHub repo a session can run against). Minimal by
 * design — the sessions home (#747) and lifecycle work fill this out as needed.
 */
export interface ReposTable {
	/** Stable repo id (GitHub node id or `owner/name`); referenced by sessions. */
	id: string;
	/** `owner/name`, the human-facing identifier. */
	full_name: string;
	/** Default branch a new session checks out; null until known. */
	default_branch: string | null;
	created_at: string;
}

/**
 * One coding session — the primary object of the app. A session owns an
 * append-only `session_events` log; its UIMessage transcript is projected from
 * that log, never stored here.
 */
export interface SessionsTable {
	id: string;
	/** repos.id this session runs against; null for not-yet-bound sessions. */
	repo_id: string | null;
	title: string;
	/** Compute provider id — "mock" | "vercel" | "anthropic" | … */
	provider: string;
	/** Lifecycle state — "active" | "idle" | "archived" (owned by #749/#750). */
	status: string;
	/** Claude CLI session id for snapshot/resume; null until a turn runs. */
	claude_session_id: string | null;
	/**
	 * JSON `HarnessAgentResumeSessionState` from the last turn's `detach()`, or
	 * null. The real (vercel) provider reconnects the parked harness session with
	 * this on the next turn so the conversation and warm sandbox continue.
	 */
	resume_state: string | null;
	/** Claude model id this session's turns run on (migration `0004_session_model`, #824). */
	model: string;
	created_at: string;
	last_activity_at: string;
}

/**
 * The append-only transcript log. Each row is one provider `StreamChunk`
 * (see agent-runtime/stream-chunk.ts) tagged with the turn's role and a
 * per-session monotonic `seq`. This is the single source of truth for a
 * session's transcript; `seq` is the resume cursor #749's tail route reads.
 */
export interface SessionEventsTable {
	session_id: string;
	/** Monotonic per session, starting at 1. (session_id, seq) is the PK. */
	seq: number;
	/** Whose turn this chunk belongs to — "user" | "assistant". */
	role: string;
	/** The StreamChunk `type` ("text" | "tool_use" | …), denormalized for cheap filtering/debugging. */
	kind: string;
	/** JSON-serialized StreamChunk payload. */
	payload: string;
	created_at: string;
}

export interface Database {
	repos: ReposTable;
	sessions: SessionsTable;
	session_events: SessionEventsTable;
}

/** A connected database: the raw client (for PRAGMA/DDL) and the typed builder. */
export interface DatabaseHandle {
	client: Client;
	db: Kysely<Database>;
}


/** Opens a fresh handle over the given libSQL URL (`file:…` or a Turso URL). */
export function openDatabase(url: string): DatabaseHandle {
	if (url.startsWith("file:")) {
		mkdirSync(dirname(url.slice("file:".length)), { recursive: true });
	}
	const client = createClient({
		url,
		authToken: process.env.SESSIONS_DATABASE_AUTH_TOKEN,
	});
	const db = new Kysely<Database>({ dialect: new LibsqlDialect({ client }) });
	return { client, db };
}

let singleton: DatabaseHandle | undefined;

/** The app-wide handle, created once from `SESSIONS_DATABASE_URL`. */
export function getDatabase(): DatabaseHandle {
	if (!singleton) {
		singleton = openDatabase(
			process.env.SESSIONS_DATABASE_URL ?? "file:.data/sessions.db",
		);
	}
	return singleton;
}
