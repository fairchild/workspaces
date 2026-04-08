import { createClient } from "@libsql/client";

const EVENT_IDS = [
	"e2e-event-ci-1",
	"e2e-event-ci-2",
	"e2e-event-ci-3",
	"e2e-event-issue-1",
	"e2e-event-push-1",
	"e2e-event-ci-4",
	"e2e-event-ci-5",
	"e2e-event-pr-1",
	"e2e-event-ci-6",
	"e2e-event-ci-7",
	"e2e-event-push-2",
];
const CHAT_IDS = ["e2e-chat-1", "e2e-chat-2", "e2e-chat-3", "e2e-chat-4"];

export default async function globalTeardown() {
	if (process.env.CI) return;

	const db = createClient({ url: "file:data/auth.db" });

	await db.execute({
		sql: "DELETE FROM user_repos WHERE user_id = ?",
		args: ["dev-user"],
	});

	for (const id of EVENT_IDS) {
		await db.execute({ sql: "DELETE FROM webhook_events WHERE id = ?", args: [id] });
	}

	for (const id of CHAT_IDS) {
		await db.execute({ sql: "DELETE FROM chat_messages WHERE id = ?", args: [id] });
	}

	// Clean up agent test data created during E2E runs
	await db.execute(
		"DELETE FROM chat_messages WHERE content LIKE '%Mock agent response%'",
	);
	await db.execute(
		"DELETE FROM chat_messages WHERE content LIKE '%@april-clearwater%' AND (content LIKE '%e2e-%' OR content LIKE '%persist-%' OR content LIKE '%first message%' OR content LIKE '%second message%')",
	);
	await db.execute(
		"DELETE FROM agent_sessions WHERE compute_backend = 'mock'",
	);

	// Clean up the seeded e2e fixtures
	await db.execute({
		sql: "DELETE FROM agent_sessions WHERE id LIKE ?",
		args: ["e2e-session-%"],
	});
}
