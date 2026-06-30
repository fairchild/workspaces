import { mkdirSync } from "node:fs";
import { createClient } from "@libsql/client";

const TEST_USER_ID = "dev-user";
const TEST_REPO = "fairchild/workspaces";
const DB_URL =
	process.env.PLAYWRIGHT_DATABASE_URL ??
	(process.env.CI ? "file:data/e2e-auth.db" : process.env.TURSO_DATABASE_URL) ??
	"file:data/auth.db";

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
	"e2e-chat-5",
	"e2e-chat-6",
];

const SESSION_IDS = [
	"e2e-session-paused-april",
	"e2e-session-review-run",
	// Add more here when we want running fixtures (running needs a real
	// sandbox or mocking — paused works without any real sandbox)
];
export const REVIEW_RUN_FINGERPRINT = "e2e-review-run-projected";

function minutesAgo(day: number, minutes: number): string {
	const d = new Date();
	d.setDate(d.getDate() - day);
	d.setHours(12, 0, 0, 0);
	d.setMinutes(d.getMinutes() - minutes);
	return d.toISOString();
}

export default async function globalSetup() {
	if (process.env.PLAYWRIGHT_SKIP_DB_FIXTURES === "1") return;

	mkdirSync("data", { recursive: true });
	const db = createClient({ url: DB_URL });

	await db.execute(`CREATE TABLE IF NOT EXISTS "user" (
		id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		email TEXT NOT NULL UNIQUE,
		emailVerified INTEGER NOT NULL DEFAULT 0,
		image TEXT,
		createdAt TEXT NOT NULL DEFAULT (datetime('now')),
		updatedAt TEXT NOT NULL DEFAULT (datetime('now'))
	)`);

	await db.execute(`CREATE TABLE IF NOT EXISTS session (
		id TEXT PRIMARY KEY,
		expiresAt TEXT NOT NULL,
		token TEXT NOT NULL UNIQUE,
		createdAt TEXT NOT NULL DEFAULT (datetime('now')),
		updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
		ipAddress TEXT,
		userAgent TEXT,
		userId TEXT NOT NULL,
		FOREIGN KEY (userId) REFERENCES "user"(id) ON DELETE CASCADE
	)`);
	await db.execute(
		"CREATE INDEX IF NOT EXISTS idx_session_userId ON session(userId)",
	);

	await db.execute(`CREATE TABLE IF NOT EXISTS account (
		id TEXT PRIMARY KEY,
		accountId TEXT NOT NULL,
		providerId TEXT NOT NULL,
		userId TEXT NOT NULL,
		accessToken TEXT,
		refreshToken TEXT,
		idToken TEXT,
		accessTokenExpiresAt TEXT,
		refreshTokenExpiresAt TEXT,
		scope TEXT,
		password TEXT,
		createdAt TEXT NOT NULL DEFAULT (datetime('now')),
		updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
		FOREIGN KEY (userId) REFERENCES "user"(id) ON DELETE CASCADE
	)`);
	await db.execute(
		"CREATE INDEX IF NOT EXISTS idx_account_userId ON account(userId)",
	);

	await db.execute(`CREATE TABLE IF NOT EXISTS verification (
		id TEXT PRIMARY KEY,
		identifier TEXT NOT NULL,
		value TEXT NOT NULL,
		expiresAt TEXT NOT NULL,
		createdAt TEXT NOT NULL DEFAULT (datetime('now')),
		updatedAt TEXT NOT NULL DEFAULT (datetime('now'))
	)`);
	await db.execute(
		"CREATE INDEX IF NOT EXISTS idx_verification_identifier ON verification(identifier)",
	);

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

	await db.execute(`CREATE TABLE IF NOT EXISTS agent_sessions (
		id TEXT PRIMARY KEY,
		user_id TEXT,
		repo TEXT NOT NULL,
		agent_name TEXT NOT NULL,
		compute_backend TEXT NOT NULL,
		compute_instance_id TEXT,
		thread_id TEXT NOT NULL,
		discussion_id TEXT,
		status TEXT NOT NULL,
		created_at TEXT NOT NULL,
		last_activity_at TEXT NOT NULL,
		snapshot_id TEXT,
		claude_session_id TEXT
	)`);

	await db.execute(`CREATE TABLE IF NOT EXISTS managed_pr_review_runs (
		fingerprint TEXT PRIMARY KEY,
		repo_full_name TEXT NOT NULL,
		pr_number INTEGER NOT NULL,
		head_sha TEXT NOT NULL,
		trigger_kind TEXT NOT NULL,
		trigger_source_id TEXT NOT NULL,
		reviewer_config_hash TEXT NOT NULL,
		session_id TEXT,
		session_started_at TEXT,
		status TEXT NOT NULL,
		created_at TEXT NOT NULL,
		updated_at TEXT NOT NULL,
		error TEXT,
		failure_kind TEXT,
		failure_message TEXT,
		failure_retryable INTEGER,
		failed_at TEXT,
		projection_status TEXT,
		projection_updated_at TEXT,
		projection_error TEXT,
		github_review_id TEXT,
		review_intent_event TEXT,
		review_intent_body TEXT,
		review_intent_labels TEXT,
		review_intent_recorded_at TEXT,
		active_claim_key TEXT,
		coalesced_head_sha TEXT,
		coalesced_trigger_kind TEXT,
		coalesced_trigger_source_id TEXT,
		coalesced_at TEXT
	)`);

	await db.execute(`CREATE TABLE IF NOT EXISTS managed_pr_review_projections (
		projection_id TEXT PRIMARY KEY,
		run_fingerprint TEXT NOT NULL,
		projection_type TEXT NOT NULL,
		projection_key TEXT NOT NULL,
		desired_payload_hash TEXT NOT NULL,
		desired_payload TEXT NOT NULL,
		state TEXT NOT NULL,
		attempts INTEGER NOT NULL DEFAULT 0,
		last_attempted_at TEXT,
		observed_external_id TEXT,
		error_kind TEXT,
		error_text TEXT,
		created_at TEXT NOT NULL,
		updated_at TEXT NOT NULL
	)`);

	// Wipe any e2e fixtures from previous runs so the test starts clean
	await db.execute({
		sql: "DELETE FROM agent_sessions WHERE id LIKE ?",
		args: ["e2e-session-%"],
	});
	await db.execute({
		sql: "DELETE FROM managed_pr_review_projections WHERE run_fingerprint = ?",
		args: [REVIEW_RUN_FINGERPRINT],
	});
	await db.execute({
		sql: "DELETE FROM managed_pr_review_runs WHERE fingerprint = ?",
		args: [REVIEW_RUN_FINGERPRINT],
	});

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
		// Default agent interaction: plain message (no @mention) routed to default agent
		{ id: CHAT_IDS[4], author: "Dev User", authorType: "user", content: "What's the project structure?", ts: minutesAgo(0, 2) },
		{ id: CHAT_IDS[5], author: "April Clearwater", authorType: "agent", content: "The project has a web/ directory with Next.js and a native Swift app.", ts: minutesAgo(0, 1) },
	];

	for (const m of messages) {
		await db.execute({
			sql: "INSERT OR IGNORE INTO chat_messages (id, repo, author, author_type, content, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
			args: [m.id, TEST_REPO, m.author, m.authorType, m.content, m.ts],
		});
	}

	// Seed one paused session so the terminal tab tests have something to
	// render the Resume / sub-tab states against. We use a fake sandbox ID;
	// the status route will report it as paused (no Sandbox.get() needed)
	// because status='snapshotted' is treated as paused without a liveness
	// check.
	const now = new Date().toISOString();
	await db.execute({
		sql: `INSERT OR REPLACE INTO agent_sessions (
			id, user_id, repo, agent_name, compute_backend, compute_instance_id,
			snapshot_id, thread_id, status, created_at, last_activity_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		args: [
			SESSION_IDS[0],
			TEST_USER_ID,
			TEST_REPO,
			"april-clearwater",
			"vercel-sandbox",
			"sbx_e2e_paused_april",
			"snap_e2e_paused_april",
			"e2e-thread-paused",
			"snapshotted",
			now,
			now,
		],
	});

	const reviewRunCreatedAt = "2026-06-30T15:00:00.000Z";
	const reviewRunSessionStartedAt = "2026-06-30T15:01:15.000Z";
	const reviewRunUpdatedAt = "2026-06-30T15:08:45.000Z";
	await db.execute({
		sql: `INSERT OR REPLACE INTO managed_pr_review_runs (
			fingerprint, repo_full_name, pr_number, head_sha, trigger_kind,
			trigger_source_id, reviewer_config_hash, session_id, session_started_at,
			status, created_at, updated_at, projection_status, projection_updated_at,
			github_review_id, review_intent_event, review_intent_body,
			review_intent_labels, review_intent_recorded_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		args: [
			REVIEW_RUN_FINGERPRINT,
			TEST_REPO,
			703,
			"5fa95de71e7a5b376a6bdd410846ce5f8fe6d56c",
			"pull_request",
			"703",
			"reviewer-config-e2e",
			SESSION_IDS[1],
			reviewRunSessionStartedAt,
			"completed",
			reviewRunCreatedAt,
			reviewRunUpdatedAt,
			"projected",
			reviewRunUpdatedAt,
			"PRR_e2e_review",
			"APPROVE",
			"E2E managed review body",
			JSON.stringify(["web"]),
			reviewRunUpdatedAt,
		],
	});
	await db.execute({
		sql: `INSERT OR REPLACE INTO managed_pr_review_projections (
			projection_id, run_fingerprint, projection_type, projection_key,
			desired_payload_hash, desired_payload, state, attempts,
			last_attempted_at, observed_external_id, created_at, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		args: [
			"e2e-review-run-projection-status",
			REVIEW_RUN_FINGERPRINT,
			"github_status",
			"WorkSpaces Managed Review",
			"sha256-e2e-status",
			JSON.stringify({ state: "success" }),
			"projected",
			1,
			reviewRunUpdatedAt,
			"status-e2e",
			reviewRunCreatedAt,
			reviewRunUpdatedAt,
		],
	});
}
