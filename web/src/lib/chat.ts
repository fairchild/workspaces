import { getDb } from "./db";
import type {
	AuthorType,
	ChatMessage,
	TimelineEntry,
	WebhookEventType,
} from "./types";

let migrated = false;

async function ensureChatTable(): Promise<void> {
	if (migrated) return;
	const db = getDb();
	await db.schema
		.createTable("chat_messages")
		.ifNotExists()
		.addColumn("id", "text", (c) => c.primaryKey())
		.addColumn("repo", "text", (c) => c.notNull())
		.addColumn("author", "text", (c) => c.notNull())
		.addColumn("author_type", "text", (c) => c.notNull())
		.addColumn("content", "text", (c) => c.notNull())
		.addColumn("agent_target", "text")
		.addColumn("discussion_id", "text")
		.addColumn("discussion_url", "text")
		.addColumn("timestamp", "text", (c) => c.notNull())
		.execute();
	await db.schema
		.createIndex("idx_chat_messages_repo_ts")
		.ifNotExists()
		.on("chat_messages")
		.columns(["repo", "timestamp desc"])
		.execute();
	migrated = true;
}

export async function pushChatMessage(msg: ChatMessage): Promise<void> {
	await ensureChatTable();
	const db = getDb();
	await db
		.insertInto("chat_messages")
		.values({
			id: msg.id,
			repo: msg.repo,
			author: msg.author,
			author_type: msg.authorType,
			content: msg.content,
			agent_target: msg.agentTarget,
			discussion_id: msg.discussionId,
			discussion_url: msg.discussionUrl,
			timestamp: msg.timestamp,
		})
		.onConflict((oc) => oc.doNothing())
		.execute();
}

export async function getChatMessages(
	repo: string,
	limit = 50,
	since?: string,
): Promise<ChatMessage[]> {
	await ensureChatTable();
	const db = getDb();
	let query = db
		.selectFrom("chat_messages")
		.selectAll()
		.where("repo", "=", repo)
		.orderBy("timestamp", "desc")
		.limit(limit);
	if (since) {
		query = query.where("timestamp", ">", since);
	}
	const rows = await query.execute();
	return rows.map((r) => ({
		id: r.id,
		repo: r.repo,
		author: r.author,
		authorType: r.author_type as AuthorType,
		content: r.content,
		agentTarget: r.agent_target,
		discussionId: r.discussion_id,
		discussionUrl: r.discussion_url,
		timestamp: r.timestamp,
	}));
}

export async function updateChatMessageContent(
	id: string,
	content: string,
): Promise<void> {
	await ensureChatTable();
	const db = getDb();
	await db
		.updateTable("chat_messages")
		.set({ content })
		.where("id", "=", id)
		.execute();
}

export async function getChatMessageByDiscussionId(
	discussionId: string,
): Promise<ChatMessage | null> {
	await ensureChatTable();
	const db = getDb();
	const row = await db
		.selectFrom("chat_messages")
		.selectAll()
		.where("discussion_id", "=", discussionId)
		.where("author_type", "=", "bot")
		.orderBy("timestamp", "desc")
		.limit(1)
		.executeTakeFirst();
	if (!row) return null;
	return {
		id: row.id,
		repo: row.repo,
		author: row.author,
		authorType: row.author_type as AuthorType,
		content: row.content,
		agentTarget: row.agent_target,
		discussionId: row.discussion_id,
		discussionUrl: row.discussion_url,
		timestamp: row.timestamp,
	};
}

export async function getMixedTimeline(
	repo: string,
	limit = 50,
	since?: string,
): Promise<TimelineEntry[]> {
	await ensureChatTable();
	const db = getDb();

	let eventsQuery = db
		.selectFrom("webhook_events")
		.select(["id", "type", "action", "summary", "repo", "timestamp"])
		.where("repo", "=", repo)
		.orderBy("timestamp", "desc")
		.limit(limit);

	let chatQuery = db
		.selectFrom("chat_messages")
		.select([
			"id",
			"repo",
			"author",
			"author_type",
			"content",
			"agent_target",
			"discussion_id",
			"discussion_url",
			"timestamp",
		])
		.where("repo", "=", repo)
		.orderBy("timestamp", "desc")
		.limit(limit);

	if (since) {
		eventsQuery = eventsQuery.where("timestamp", ">", since);
		chatQuery = chatQuery.where("timestamp", ">", since);
	}

	const [events, messages] = await Promise.all([
		eventsQuery.execute(),
		chatQuery.execute(),
	]);

	const timeline: TimelineEntry[] = [
		...events.map((e) => ({
			kind: "event" as const,
			id: e.id,
			type: e.type as WebhookEventType,
			action: e.action,
			summary: e.summary,
			repo: e.repo,
			timestamp: e.timestamp,
		})),
		...messages.map((m) => ({
			kind: "chat" as const,
			id: m.id,
			repo: m.repo,
			author: m.author,
			authorType: m.author_type as AuthorType,
			content: m.content,
			agentTarget: m.agent_target,
			discussionId: m.discussion_id,
			discussionUrl: m.discussion_url,
			timestamp: m.timestamp,
		})),
	];

	timeline.sort((a, b) => (a.timestamp > b.timestamp ? -1 : 1));
	return timeline.slice(0, limit);
}
