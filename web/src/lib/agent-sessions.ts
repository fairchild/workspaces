import { getDb } from "./db";
import type {
	AgentSession,
	AgentSessionStatus,
	ComputeBackendId,
} from "./types";

let migrated = false;

async function ensureSessionTable(): Promise<void> {
	if (migrated) return;
	const db = getDb();
	await db.schema
		.createTable("agent_sessions")
		.ifNotExists()
		.addColumn("id", "text", (c) => c.primaryKey())
		.addColumn("repo", "text", (c) => c.notNull())
		.addColumn("agent_name", "text", (c) => c.notNull())
		.addColumn("compute_backend", "text", (c) => c.notNull())
		.addColumn("compute_instance_id", "text")
		.addColumn("thread_id", "text", (c) => c.notNull())
		.addColumn("discussion_id", "text")
		.addColumn("status", "text", (c) => c.notNull())
		.addColumn("created_at", "text", (c) => c.notNull())
		.addColumn("last_activity_at", "text", (c) => c.notNull())
		.execute();
	await db.schema
		.createIndex("idx_agent_sessions_thread")
		.ifNotExists()
		.on("agent_sessions")
		.columns(["repo", "agent_name", "thread_id"])
		.execute();
	migrated = true;
}

function rowToSession(r: {
	id: string;
	repo: string;
	agent_name: string;
	compute_backend: string;
	compute_instance_id: string | null;
	thread_id: string;
	discussion_id: string | null;
	status: string;
	created_at: string;
	last_activity_at: string;
}): AgentSession {
	return {
		id: r.id,
		repo: r.repo,
		agentName: r.agent_name,
		computeBackend: r.compute_backend as ComputeBackendId,
		computeInstanceId: r.compute_instance_id,
		threadId: r.thread_id,
		discussionId: r.discussion_id,
		status: r.status as AgentSessionStatus,
		createdAt: r.created_at,
		lastActivityAt: r.last_activity_at,
	};
}

export async function createSession(session: AgentSession): Promise<void> {
	await ensureSessionTable();
	const db = getDb();
	await db
		.insertInto("agent_sessions")
		.values({
			id: session.id,
			repo: session.repo,
			agent_name: session.agentName,
			compute_backend: session.computeBackend,
			compute_instance_id: session.computeInstanceId,
			thread_id: session.threadId,
			discussion_id: session.discussionId,
			status: session.status,
			created_at: session.createdAt,
			last_activity_at: session.lastActivityAt,
		})
		.onConflict((oc) => oc.doNothing())
		.execute();
}

export async function getSession(id: string): Promise<AgentSession | null> {
	await ensureSessionTable();
	const db = getDb();
	const row = await db
		.selectFrom("agent_sessions")
		.selectAll()
		.where("id", "=", id)
		.executeTakeFirst();
	return row ? rowToSession(row) : null;
}

export async function getActiveSessionForThread(
	repo: string,
	agentName: string,
	threadId: string,
): Promise<AgentSession | null> {
	await ensureSessionTable();
	const db = getDb();
	const row = await db
		.selectFrom("agent_sessions")
		.selectAll()
		.where("repo", "=", repo)
		.where("agent_name", "=", agentName)
		.where("thread_id", "=", threadId)
		.where("status", "in", ["starting", "active", "streaming"])
		.orderBy("last_activity_at", "desc")
		.limit(1)
		.executeTakeFirst();
	return row ? rowToSession(row) : null;
}

export async function updateSessionStatus(
	id: string,
	status: AgentSessionStatus,
): Promise<void> {
	await ensureSessionTable();
	const db = getDb();
	await db
		.updateTable("agent_sessions")
		.set({ status, last_activity_at: new Date().toISOString() })
		.where("id", "=", id)
		.execute();
}

export async function updateComputeInstance(
	id: string,
	computeInstanceId: string,
): Promise<void> {
	await ensureSessionTable();
	const db = getDb();
	await db
		.updateTable("agent_sessions")
		.set({ compute_instance_id: computeInstanceId })
		.where("id", "=", id)
		.execute();
}
