import { mkdirSync } from "node:fs";
import { createClient } from "@libsql/client";

const TEST_USER_ID = "dev-user";
const TEST_REPO = "fairchild/workspaces";
const DB_PATH = "data/auth.db";

// Deterministic IDs for cleanup
const EVENT_IDS = [
	// Day 1 (yesterday) — burst of CI events that should collapse
	"e2e-event-ci-1",
	"e2e-event-ci-2",
	"e2e-event-ci-3",
	"e2e-event-issue-1",
	// Day 0 (today) — events before/between/after chat messages
	"e2e-event-push-1",
	"e2e-event-ci-4",
	"e2e-event-ci-5",
	"e2e-event-pr-1",
	// Events after first chat message (should form second group)
	"e2e-event-ci-6",
	"e2e-event-ci-7",
	"e2e-event-push-2",
];
const CHAT_IDS = [
	"e2e-chat-1",
	"e2e-chat-2",
	"e2e-chat-3",
	"e2e-chat-4",
];

function minutesAgo(day: number, minutes: number): string {
	const d = new Date();
	d.setDate(d.getDate() - day);
	d.setHours(12, 0, 0, 0);
	d.setMinutes(d.getMinutes() - minutes);
	return d.toISOString();
}

export default async function globalSetup() {
	if (process.env.CI) return;

	mkdirSync("data", { recursive: true });
	const db = createClient({ url: `file:${DB_PATH}` });

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

	// --- Day 1 (yesterday): burst of events + 1 chat message ---
	const events = [
		// Yesterday: 3 CI + 1 ISSUE in a row (should collapse into group)
		{ id: EVENT_IDS[0], type: "check_run", action: "completed", summary: "Web CI: success", ts: minutesAgo(1, 30) },
		{ id: EVENT_IDS[1], type: "check_run", action: "completed", summary: "Lint: success", ts: minutesAgo(1, 29) },
		{ id: EVENT_IDS[2], type: "check_run", action: "completed", summary: "Evidence Reminder: skipped", ts: minutesAgo(1, 28) },
		{ id: EVENT_IDS[3], type: "issues", action: "opened", summary: "opened: improve chat UX", ts: minutesAgo(1, 27) },

		// Today: 4 events before chat (should collapse)
		{ id: EVENT_IDS[4], type: "push", action: "push", summary: "2 commit(s) to main", ts: minutesAgo(0, 20) },
		{ id: EVENT_IDS[5], type: "check_run", action: "completed", summary: "Web CI: requested", ts: minutesAgo(0, 19) },
		{ id: EVENT_IDS[6], type: "check_run", action: "completed", summary: "Vercel Preview: success", ts: minutesAgo(0, 18) },
		{ id: EVENT_IDS[7], type: "pull_request", action: "opened", summary: "opened #271: collapse events in chat", ts: minutesAgo(0, 17) },

		// Today: 3 events after first chat exchange (should collapse)
		{ id: EVENT_IDS[8], type: "check_run", action: "completed", summary: "Web CI: success", ts: minutesAgo(0, 8) },
		{ id: EVENT_IDS[9], type: "check_run", action: "completed", summary: "Lint, Typecheck & Build: success", ts: minutesAgo(0, 7) },
		{ id: EVENT_IDS[10], type: "push", action: "push", summary: "1 commit(s) to feat/chat-e2e", ts: minutesAgo(0, 6) },
	];

	for (const e of events) {
		await db.execute({
			sql: "INSERT OR IGNORE INTO webhook_events (id, type, action, summary, repo, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
			args: [e.id, e.type, e.action, e.summary, TEST_REPO, e.ts],
		});
	}

	// Chat messages — interspersed with events to test grouping
	const messages = [
		// Yesterday: 1 message (between yesterday's events and today's)
		{ id: CHAT_IDS[0], author: "Dev User", authorType: "user", content: "Hello from yesterday", ts: minutesAgo(1, 10) },
		// Today: user message breaks the first event group
		{ id: CHAT_IDS[1], author: "Dev User", authorType: "user", content: "@april-clearwater summarize the readme", ts: minutesAgo(0, 15) },
		// Today: agent response
		{ id: CHAT_IDS[2], author: "april-clearwater", authorType: "agent", content: "Workspaces is a terminal-first workspace manager for AI coding sessions on macOS.", ts: minutesAgo(0, 14) },
		// Today: another user message after the second event group
		{ id: CHAT_IDS[3], author: "Dev User", authorType: "user", content: "Thanks! Can you check the open issues?", ts: minutesAgo(0, 3) },
	];

	for (const m of messages) {
		await db.execute({
			sql: "INSERT OR IGNORE INTO chat_messages (id, repo, author, author_type, content, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
			args: [m.id, TEST_REPO, m.author, m.authorType, m.content, m.ts],
		});
	}
}
