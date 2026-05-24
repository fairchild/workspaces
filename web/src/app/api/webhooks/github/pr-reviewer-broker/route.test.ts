import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	processPendingPrReviewRuns: vi.fn(),
}));

vi.mock("@/lib/agent-runtime/pr-review", () => ({
	processPendingPrReviewRuns: mocks.processPendingPrReviewRuns,
}));

const BROKER_SECRET = "broker-secret";

function brokerRequest(headers: Record<string, string> = {}): Request {
	return new Request(
		"http://localhost/api/webhooks/github/pr-reviewer-broker?limit=3",
		{ method: "POST", headers },
	);
}

describe("/api/webhooks/github/pr-reviewer-broker POST", () => {
	beforeEach(() => {
		vi.resetModules();
		vi.stubEnv("WORKSPACES_WEBHOOK_CANARY_SECRET", BROKER_SECRET);
		vi.stubEnv("PR_REVIEWER_ENABLED", "");
		mocks.processPendingPrReviewRuns.mockReset();
		mocks.processPendingPrReviewRuns.mockResolvedValue({
			checked: 1,
			completed: 1,
			failed: 0,
			skippedRunning: 0,
			superseded: 0,
			requeued: 0,
			runs: [
				{
					fingerprint: "fp",
					sessionId: "sesn_123",
					prNumber: 486,
					status: "completed",
				},
			],
		});
	});

	afterEach(() => {
		vi.unstubAllEnvs();
		vi.restoreAllMocks();
	});

	it("rejects requests without the canary secret", async () => {
		const { POST } = await import("./route");
		const response = await POST(brokerRequest());

		expect(response.status).toBe(401);
		await expect(response.json()).resolves.toMatchObject({
			ok: false,
			error: "unauthorized",
		});
		expect(mocks.processPendingPrReviewRuns).not.toHaveBeenCalled();
	});

	it("processes pending runs when authenticated", async () => {
		const { POST } = await import("./route");
		const response = await POST(
			brokerRequest({ "x-workspace-webhook-canary": BROKER_SECRET }),
		);

		expect(response.status).toBe(200);
		expect(mocks.processPendingPrReviewRuns).toHaveBeenCalledWith({
			limit: 3,
			repoFullName: undefined,
		});
		await expect(response.json()).resolves.toMatchObject({
			ok: true,
			checked: 1,
			completed: 1,
			failed: 0,
		});
	});

	it("accepts bearer auth and reports broker failures", async () => {
		mocks.processPendingPrReviewRuns.mockResolvedValue({
			checked: 1,
			completed: 0,
			failed: 1,
			skippedRunning: 0,
			superseded: 0,
			requeued: 0,
			runs: [
				{
					fingerprint: "fp",
					sessionId: "sesn_123",
					prNumber: 486,
					status: "failed",
					error: "No valid PR review intent JSON found",
				},
			],
		});

		const { POST } = await import("./route");
		const response = await POST(
			brokerRequest({ authorization: `Bearer ${BROKER_SECRET}` }),
		);

		expect(response.status).toBe(200);
		await expect(response.json()).resolves.toMatchObject({
			ok: false,
			checked: 1,
			failed: 1,
		});
	});

	it("returns not configured when the shared secret is missing", async () => {
		vi.stubEnv("WORKSPACES_WEBHOOK_CANARY_SECRET", "");
		const { POST } = await import("./route");
		const response = await POST(brokerRequest());

		expect(response.status).toBe(404);
		await expect(response.json()).resolves.toMatchObject({
			ok: false,
			error: "broker_not_configured",
		});
	});
});
