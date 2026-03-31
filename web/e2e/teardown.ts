import { createClient } from "@libsql/client";

const EVENT_IDS = [
	"e2e-event-ci-1",
	"e2e-event-pr-1",
	"e2e-event-push-1",
	"e2e-event-issue-1",
	"e2e-event-ci-2",
];
const CHAT_IDS = ["e2e-chat-1", "e2e-chat-2", "e2e-chat-3"];

export default async function globalTeardown() {
	// Skip in CI — seeding was skipped too
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
}
