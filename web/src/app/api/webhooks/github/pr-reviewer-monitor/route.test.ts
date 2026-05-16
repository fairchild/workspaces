import { PR_REVIEW_WEBHOOK_CONTRACT_CASES } from "@/lib/agent-runtime/__tests__/pr-review-trigger-fixtures";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	executeWebhookQuery: vi.fn(),
	getDb: vi.fn(),
	listRecentPrReviewRuns: vi.fn(),
	select: vi.fn(),
	selectFrom: vi.fn(),
	where: vi.fn(),
}));

vi.mock("@/lib/db", () => ({
	getDb: mocks.getDb,
}));

vi.mock("@/lib/agent-runtime/pr-review-runs", () => ({
	listRecentPrReviewRuns: mocks.listRecentPrReviewRuns,
}));

const MONITOR_SECRET = "monitor-secret";

function webhookRowFromContractCase(
	testCase: (typeof PR_REVIEW_WEBHOOK_CONTRACT_CASES)[number],
) {
	const payload = testCase.payload as { action?: string };
	return {
		id: testCase.deliveryId,
		type: testCase.eventType,
		action: String(payload.action ?? ""),
		timestamp: new Date().toISOString(),
		payload: JSON.stringify(testCase.payload),
	};
}

function monitorRequest(headers: Record<string, string> = {}): Request {
	return new Request(
		"http://localhost/api/webhooks/github/pr-reviewer-monitor?windowMinutes=90",
		{ headers },
	);
}

describe("/api/webhooks/github/pr-reviewer-monitor GET", () => {
	beforeEach(() => {
		vi.resetModules();
		vi.stubEnv("WORKSPACES_WEBHOOK_CANARY_SECRET", MONITOR_SECRET);
		vi.stubEnv("PR_REVIEWER_ENABLED", "");

		mocks.executeWebhookQuery.mockReset();
		mocks.getDb.mockReset();
		mocks.listRecentPrReviewRuns.mockReset();
		mocks.select.mockReset();
		mocks.selectFrom.mockReset();
		mocks.where.mockReset();

		const query = {
			select: mocks.select.mockReturnThis(),
			where: mocks.where.mockReturnThis(),
			execute: mocks.executeWebhookQuery,
		};
		mocks.getDb.mockReturnValue({
			selectFrom: mocks.selectFrom.mockReturnValue(query),
		});
	});

	afterEach(() => {
		vi.unstubAllEnvs();
		vi.restoreAllMocks();
	});

	it("rejects requests without the canary secret", async () => {
		const { GET } = await import("./route");
		const response = await GET(monitorRequest());

		expect(response.status).toBe(401);
		await expect(response.json()).resolves.toMatchObject({
			ok: false,
			error: "unauthorized",
		});
		expect(mocks.getDb).not.toHaveBeenCalled();
	});

	it("returns ok when every eligible webhook has a matching run row", async () => {
		const opened = PR_REVIEW_WEBHOOK_CONTRACT_CASES[0];
		mocks.executeWebhookQuery.mockResolvedValue([
			webhookRowFromContractCase(opened),
		]);
		mocks.listRecentPrReviewRuns.mockResolvedValue([
			{
				repoFullName: "fairchild/workspaces",
				prNumber: 8101,
				headSha: "abc8101def456",
				triggerKind: "opened",
				triggerSourceId: "abc8101def456",
				status: "started",
				sessionId: "sesn_123",
				createdAt: new Date().toISOString(),
				updatedAt: new Date().toISOString(),
			},
		]);

		const { GET } = await import("./route");
		const response = await GET(
			monitorRequest({ "x-workspace-webhook-canary": MONITOR_SECRET }),
		);

		expect(response.status).toBe(200);
		await expect(response.json()).resolves.toMatchObject({
			ok: true,
			checked: 1,
			missing: [],
		});
	});

	it("matches evidence-comment runs after the runtime resolves the PR head SHA", async () => {
		const evidenceComment = PR_REVIEW_WEBHOOK_CONTRACT_CASES.find(
			(testCase) => testCase.expectedTriggerKind === "evidence_comment",
		);
		if (!evidenceComment) throw new Error("missing evidence comment fixture");
		mocks.executeWebhookQuery.mockResolvedValue([
			webhookRowFromContractCase(evidenceComment),
		]);
		mocks.listRecentPrReviewRuns.mockResolvedValue([
			{
				repoFullName: "fairchild/workspaces",
				prNumber: 8111,
				headSha: "resolved-head-sha",
				triggerKind: "evidence_comment",
				triggerSourceId: "comment-908111",
				status: "completed",
				sessionId: "sesn_456",
				createdAt: new Date().toISOString(),
				updatedAt: new Date().toISOString(),
			},
		]);

		const { GET } = await import("./route");
		const response = await GET(
			monitorRequest({ "x-workspace-webhook-canary": MONITOR_SECRET }),
		);

		expect(response.status).toBe(200);
		await expect(response.json()).resolves.toMatchObject({
			ok: true,
			checked: 1,
			missing: [],
		});
	});

	it("returns 503 with metadata when an eligible webhook has no run row", async () => {
		const opened = PR_REVIEW_WEBHOOK_CONTRACT_CASES[0];
		mocks.executeWebhookQuery.mockResolvedValue([
			webhookRowFromContractCase(opened),
		]);
		mocks.listRecentPrReviewRuns.mockResolvedValue([]);

		const { GET } = await import("./route");
		const response = await GET(
			monitorRequest({ "x-workspace-webhook-canary": MONITOR_SECRET }),
		);

		expect(response.status).toBe(503);
		await expect(response.json()).resolves.toMatchObject({
			ok: false,
			checked: 1,
			missing: [
				{
					eventId: "contract-pr-opened",
					repoFullName: "fairchild/workspaces",
					prNumber: 8101,
					triggerKind: "opened",
					triggerSourceId: "abc8101def456",
				},
			],
		});
	});
});
