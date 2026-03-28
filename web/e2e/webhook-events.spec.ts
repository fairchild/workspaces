import { test, expect } from "@playwright/test";

const WEBHOOK_URL = "/api/webhooks/github";
const AUTH_HEADERS = { Cookie: "better-auth.session_token=e2e-test-token" };

function webhookHeaders(type: string, id?: string) {
	return {
		"Content-Type": "application/json",
		"x-github-event": type,
		"x-github-delivery": id ?? `test-${Date.now()}-${Math.random()}`,
	};
}

test.describe("Webhook event ingestion", () => {
	test("stores a pull_request event and lists it without payload", async ({
		request,
	}) => {
		const deliveryId = `test-pr-${Date.now()}`;
		const payload = {
			action: "opened",
			pull_request: {
				number: 42,
				title: "feat: add dark mode",
				html_url: "https://github.com/test/repo/pull/42",
				body: "Adds dark mode support across the dashboard",
				additions: 150,
				deletions: 30,
				changed_files: 8,
			},
			repository: { full_name: "test/repo" },
			sender: { login: "testuser" },
		};

		const res = await request.post(WEBHOOK_URL, {
			headers: webhookHeaders("pull_request", deliveryId),
			data: payload,
		});
		expect(res.ok()).toBe(true);

		const listRes = await request.get("/api/events?repo=test/repo", {
			headers: AUTH_HEADERS,
		});
		expect(listRes.ok()).toBe(true);

		const events = await listRes.json();
		const event = events.find(
			(e: { id: string }) => e.id === deliveryId,
		);
		expect(event).toBeTruthy();
		expect(event.summary).toContain("#42");
		expect(event.payload).toBeUndefined();
	});

	test("returns full payload via single event endpoint", async ({
		request,
	}) => {
		const deliveryId = `test-detail-${Date.now()}`;
		const payload = {
			action: "opened",
			issue: {
				number: 7,
				title: "Bug: login fails",
				html_url: "https://github.com/test/repo/issues/7",
				body: "Login button does nothing on Safari",
				labels: [{ name: "bug" }, { name: "priority:high" }],
			},
			repository: { full_name: "test/repo" },
			sender: { login: "reporter" },
		};

		await request.post(WEBHOOK_URL, {
			headers: webhookHeaders("issues", deliveryId),
			data: payload,
		});

		const detailRes = await request.get(`/api/events/${deliveryId}`, {
			headers: AUTH_HEADERS,
		});
		expect(detailRes.ok()).toBe(true);

		const detail = await detailRes.json();
		expect(detail.id).toBe(deliveryId);
		expect(detail.payload).toBeTruthy();

		const parsed = JSON.parse(detail.payload);
		expect(parsed.issue.html_url).toBe(
			"https://github.com/test/repo/issues/7",
		);
		expect(parsed.sender.login).toBe("reporter");
	});

	test("returns 404 for nonexistent event", async ({ request }) => {
		const res = await request.get("/api/events/nonexistent-id-12345", {
			headers: AUTH_HEADERS,
		});
		expect(res.status()).toBe(404);
	});

	test("stores push event with commits and compare URL", async ({
		request,
	}) => {
		const deliveryId = `test-push-${Date.now()}`;
		const payload = {
			ref: "refs/heads/main",
			compare: "https://github.com/test/repo/compare/abc...def",
			commits: [
				{ id: "abc1234567890", message: "fix: resolve crash" },
				{ id: "def9876543210", message: "chore: update deps" },
			],
			repository: { full_name: "test/repo" },
			sender: { login: "pusher" },
		};

		await request.post(WEBHOOK_URL, {
			headers: webhookHeaders("push", deliveryId),
			data: payload,
		});

		const detailRes = await request.get(`/api/events/${deliveryId}`, {
			headers: AUTH_HEADERS,
		});
		const detail = await detailRes.json();
		const parsed = JSON.parse(detail.payload);
		expect(parsed.compare).toBe(
			"https://github.com/test/repo/compare/abc...def",
		);
		expect(parsed.commits).toHaveLength(2);
	});

	test("ignores unsupported event types gracefully", async ({ request }) => {
		const res = await request.post(WEBHOOK_URL, {
			headers: webhookHeaders("star"),
			data: { action: "created", repository: { full_name: "test/repo" } },
		});
		expect(res.ok()).toBe(true);
	});
});
