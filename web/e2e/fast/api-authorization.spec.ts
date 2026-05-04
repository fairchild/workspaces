import { createHmac } from "node:crypto";
import { createClient, type Client } from "@libsql/client";
import { expect, test } from "@playwright/test";

const DB_URL =
	process.env.PLAYWRIGHT_DATABASE_URL ??
	(process.env.CI ? "file:data/e2e-auth.db" : process.env.TURSO_DATABASE_URL) ??
	"file:data/auth.db";
const BASE_URL = process.env.PLAYWRIGHT_BASE_URL ?? "http://localhost:3000";
const RUNNING_AGAINST_DEPLOYED_APP =
	process.env.PLAYWRIGHT_SKIP_WEB_SERVER === "1";

const USER_A = {
	id: "e2e-authz-user-a",
	name: "E2E Authz User A",
	email: "e2e-authz-user-a@example.test",
	token: "e2e-authz-token-a",
	repo: "e2e-authz-a/repo-a",
};
const USER_B = {
	id: "e2e-authz-user-b",
	name: "E2E Authz User B",
	email: "e2e-authz-user-b@example.test",
	token: "e2e-authz-token-b",
	repo: "e2e-authz-b/repo-b",
};

const DEV_BYPASS_USER_ID = "dev-user";
const EVENT_B_ID = "e2e-authz-event-b";
const MANAGED_INSTANCE_ID = "test-managed-session-1";

function sessionCookie(token: string): string {
	const secret =
		process.env.BETTER_AUTH_SECRET ?? "ci-placeholder-secret-for-build-only";
	const signature = createHmac("sha256", secret).update(token).digest("base64");
	return `better-auth.session_token=${token}.${signature}`;
}

function invalidSessionCookie(): string {
	return "better-auth.session_token=not-a-real-session.invalid-signature";
}

async function cleanupAuthzFixtures(db: Client) {
	for (const id of [
		"e2e-authz-session-a",
		"e2e-authz-session-b",
		"e2e-authz-managed-session-b",
		"e2e-authz-managed-session-dev",
	]) {
		await db.execute({
			sql: "DELETE FROM agent_sessions WHERE id = ?",
			args: [id],
		});
		await db.execute({ sql: "DELETE FROM session WHERE id = ?", args: [id] });
	}

	await db.execute({
		sql: "DELETE FROM webhook_events WHERE id = ?",
		args: [EVENT_B_ID],
	});
	await db.execute({
		sql: "DELETE FROM user_repos WHERE user_id IN (?, ?) OR owner IN (?, ?)",
		args: [USER_A.id, USER_B.id, "e2e-authz-a", "e2e-authz-b"],
	});
	await db.execute({
		sql: 'DELETE FROM "user" WHERE id IN (?, ?)',
		args: [USER_A.id, USER_B.id],
	});
}

async function seedAuthzFixtures(db: Client) {
	await cleanupAuthzFixtures(db);

	const now = new Date().toISOString();
	const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

	for (const user of [USER_A, USER_B]) {
		await db.execute({
			sql: `INSERT INTO "user" (
				id, name, email, emailVerified, image, createdAt, updatedAt
			) VALUES (?, ?, ?, 1, NULL, ?, ?)`,
			args: [user.id, user.name, user.email, now, now],
		});
		await db.execute({
			sql: `INSERT INTO session (
				id, expiresAt, token, createdAt, updatedAt, ipAddress, userAgent, userId
			) VALUES (?, ?, ?, ?, ?, NULL, 'playwright-api-authorization', ?)`,
			args: [
				user.id === USER_A.id ? "e2e-authz-session-a" : "e2e-authz-session-b",
				expiresAt,
				user.token,
				now,
				now,
				user.id,
			],
		});
	}

	for (const user of [USER_A, USER_B]) {
		const [owner, repo] = user.repo.split("/");
		await db.execute({
			sql: `INSERT INTO user_repos (
				user_id, owner, repo, added_at
			) VALUES (?, ?, ?, ?)`,
			args: [user.id, owner, repo, now],
		});
	}

	const [ownerB, repoB] = USER_B.repo.split("/");
	await db.execute({
		sql: `INSERT INTO webhook_events (
			id, type, action, summary, repo, timestamp, payload
		) VALUES (?, 'push', 'push', 'cross-tenant event', ?, ?, '{}')`,
		args: [EVENT_B_ID, `${ownerB}/${repoB}`, now],
	});

	for (const row of [
		{
			id: "e2e-authz-managed-session-b",
			userId: USER_B.id,
			repo: USER_A.repo,
		},
		{
			id: "e2e-authz-managed-session-dev",
			userId: DEV_BYPASS_USER_ID,
			repo: USER_A.repo,
		},
	]) {
		await db.execute({
			sql: `INSERT INTO agent_sessions (
				id, user_id, repo, agent_name, compute_backend, compute_instance_id,
				thread_id, discussion_id, status, created_at, last_activity_at,
				snapshot_id, claude_session_id
			) VALUES (?, ?, ?, 'april-clearwater', 'managed-agents', ?, ?, NULL,
				'active', ?, ?, NULL, NULL)`,
			args: [
				row.id,
				row.userId,
				row.repo,
				MANAGED_INSTANCE_ID,
				`e2e-authz-thread-${row.userId}`,
				now,
				now,
			],
		});
	}
}

function expectForbidden(response: { status(): number }) {
	expect(response.status()).toBe(403);
}

test.describe("API authorization", () => {
	test.describe.configure({ mode: "serial" });
	test.skip(
		RUNNING_AGAINST_DEPLOYED_APP,
		"local seeded-DB authorization coverage cannot run against deployed apps",
	);

	let db: Client | undefined;

	test.beforeAll(async () => {
		db = createClient({ url: DB_URL });
		await seedAuthzFixtures(db);
	});

	test.afterAll(async () => {
		if (db) await cleanupAuthzFixtures(db);
	});

	test("GET /api/events?repo rejects another user's repo", async ({
		request,
	}) => {
		const response = await request.get(
			`/api/events?repo=${encodeURIComponent(USER_B.repo)}`,
			{ headers: { Cookie: sessionCookie(USER_A.token) } },
		);

		expectForbidden(response);
	});

	test("GET /api/events/:id rejects an event from another user's repo", async ({
		request,
	}) => {
		const response = await request.get(`/api/events/${EVENT_B_ID}`, {
			headers: { Cookie: sessionCookie(USER_A.token) },
		});

		expectForbidden(response);
	});

	test("GET /api/events without a valid session returns unauthorized", async ({
		playwright,
	}) => {
		test.skip(
			!process.env.CI && process.env.PLAYWRIGHT_SKIP_WEB_SERVER !== "1",
			"local Playwright webServer runs with DEV_BYPASS_AUTH=1",
		);

		const anonymous = await playwright.request.newContext({ baseURL: BASE_URL });
		const response = await anonymous.get("/api/events", {
			headers: { Cookie: invalidSessionCookie() },
		});
		await anonymous.dispose();

		expect(response.status()).toBe(401);
	});

	test("GET /api/events/stats without a valid session returns unauthorized", async ({
		playwright,
	}) => {
		test.skip(
			!process.env.CI && process.env.PLAYWRIGHT_SKIP_WEB_SERVER !== "1",
			"local Playwright webServer runs with DEV_BYPASS_AUTH=1",
		);

		const anonymous = await playwright.request.newContext({ baseURL: BASE_URL });
		const response = await anonymous.get("/api/events/stats", {
			headers: { Cookie: invalidSessionCookie() },
		});
		await anonymous.dispose();

		expect(response.status()).toBe(401);
	});

	test("GET /api/chat/messages rejects another user's repo", async ({
		request,
	}) => {
		const response = await request.get(
			`/api/chat/messages?repo=${encodeURIComponent(USER_B.repo)}`,
			{ headers: { Cookie: sessionCookie(USER_A.token) } },
		);

		expectForbidden(response);
	});

	test("GET /api/repos/:owner/:repo/agents rejects another user's repo", async ({
		request,
	}) => {
		const response = await request.get(`/api/repos/${USER_B.repo}/agents`, {
			headers: { Cookie: sessionCookie(USER_A.token) },
		});

		expectForbidden(response);
	});

	test("GET /api/repos/:owner/:repo/webhook-status rejects another user's repo", async ({
		request,
	}) => {
		const response = await request.get(
			`/api/repos/${USER_B.repo}/webhook-status`,
			{ headers: { Cookie: sessionCookie(USER_A.token) } },
		);

		expectForbidden(response);
	});

	test("GET /api/managed-agents/transcript rejects a session for an unauthorized repo", async ({
		request,
	}) => {
		const response = await request.get(
			`/api/managed-agents/transcript?sessionId=${encodeURIComponent(
				MANAGED_INSTANCE_ID,
			)}`,
			{ headers: { Cookie: sessionCookie(USER_B.token) } },
		);

		expectForbidden(response);
	});
});
