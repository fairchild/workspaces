import { existsSync, mkdirSync } from "node:fs";
import { createClient } from "@libsql/client";

const TEST_USER_ID = "dev-user";
const TEST_REPO = "fairchild/workspaces";
const DB_PATH = "data/auth.db";

// Deterministic IDs for cleanup
const EVENT_IDS = [
	"e2e-event-ci-1",
	"e2e-event-pr-1",
	"e2e-event-push-1",
	"e2e-event-issue-1",
	"e2e-event-ci-2",
];
const CHAT_IDS = ["e2e-chat-1", "e2e-chat-2", "e2e-chat-3"];

function daysAgo(n: number): string {
	const d = new Date();
	d.setDate(d.getDate() - n);
	d.setHours(12, 0, 0, 0);
	return d.toISOString();
}

export default async function globalSetup() {
	// Skip seeding in CI — only full-path tests need seeded data
	if (process.env.CI) return;

	mkdirSync("data", { recursive: true });
	const db = createClient({ url: `file:${DB_PATH}` });

	// Ensure tables exist
	await db.execute(`CREATE TABLE IF NOT EXISTS user_repos (
		user_id TEXT NOT NULL,
		owner TEXT NOT NULL,
		repo TEXT NOT NULL,
		added_at TEXT NOT NULL DEFAULT (datetime('now')),
		PRIMARY KEY (user_id, owner, repo)
	)`);

	await db.execute(`CREATE TABLE IF NOT EXISTS webhook_events (
		id TEXT PRIMARY KEY,
		type TEXT NOT NULL,
		action TEXT NOT NULL,
		summary TEXT NOT NULL,
		repo TEXT NOT NULL,
		timestamp TEXT NOT NULL,
		payload TEXT NOT NULL DEFAULT '{}'
	)`);

	await db.execute(`CREATE TABLE IF NOT EXISTS chat_messages (
		id TEXT PRIMARY KEY,
		repo TEXT NOT NULL,
		author TEXT NOT NULL,
		author_type TEXT NOT NULL,
		content TEXT NOT NULL,
		agent_target TEXT,
		discussion_id TEXT,
		discussion_url TEXT,
		timestamp TEXT NOT NULL
	)`);

	// Seed user repo
	await db.execute({
		sql: "INSERT OR IGNORE INTO user_repos (user_id, owner, repo) VALUES (?, 'fairchild', 'workspaces')",
		args: [TEST_USER_ID],
	});

	// Seed webhook events across 2 days
	const events = [
		{
			id: EVENT_IDS[0],
			type: "check_run",
			action: "completed",
			summary: "Web CI: success",
			ts: daysAgo(0),
		},
		{
			id: EVENT_IDS[1],
			type: "pull_request",
			action: "opened",
			summary: "opened #100: test PR",
			ts: daysAgo(0),
		},
		{
			id: EVENT_IDS[2],
			type: "push",
			action: "push",
			summary: "1 commit(s) to main",
			ts: daysAgo(0),
		},
		{
			id: EVENT_IDS[3],
			type: "issues",
			action: "opened",
			summary: "opened: test issue",
			ts: daysAgo(1),
		},
		{
			id: EVENT_IDS[4],
			type: "check_run",
			action: "completed",
			summary: "Lint: success",
			ts: daysAgo(1),
		},
	];

	for (const e of events) {
		await db.execute({
			sql: "INSERT OR IGNORE INTO webhook_events (id, type, action, summary, repo, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
			args: [e.id, e.type, e.action, e.summary, TEST_REPO, e.ts],
		});
	}

	// Seed chat messages across 2 days
	const messages = [
		{
			id: CHAT_IDS[0],
			author: "Dev User",
			content: "Hello from day 1",
			ts: daysAgo(1),
		},
		{
			id: CHAT_IDS[1],
			author: "spaces-bot",
			authorType: "bot",
			content: "Bot response from day 1",
			ts: daysAgo(1),
		},
		{
			id: CHAT_IDS[2],
			author: "Dev User",
			content: "Message from today",
			ts: daysAgo(0),
		},
	];

	for (const m of messages) {
		await db.execute({
			sql: "INSERT OR IGNORE INTO chat_messages (id, repo, author, author_type, content, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
			args: [
				m.id,
				TEST_REPO,
				m.author,
				m.authorType ?? "user",
				m.content,
				m.ts,
			],
		});
	}
}
