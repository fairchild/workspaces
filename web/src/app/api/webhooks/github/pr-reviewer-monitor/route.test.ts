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

vi.mock("@/lib/agent-runtime/pr-review-runs", async (importOriginal) => {
	const actual =
		await importOriginal<typeof import("@/lib/agent-runtime/pr-review-runs")>();
	return {
		...actual,
		listRecentPrReviewRuns: mocks.listRecentPrReviewRuns,
	};
});

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

function runRow(
	overrides: Partial<{
		fingerprint: string;
		repoFullName: string;
		prNumber: number;
		headSha: string;
		triggerKind: string;
		triggerSourceId: string;
		status: "started" | "completed" | "failed" | "superseded";
		sessionId: string | null;
		createdAt: string;
		updatedAt: string;
		error: string | null;
		projectionStatus: "pending" | "projected" | "failed" | "superseded";
		projectionUpdatedAt: string;
		projectionError: string | null;
		githubReviewId: string | null;
	}> = {},
) {
	const now = new Date().toISOString();
	const status = overrides.status ?? "started";
	return {
		fingerprint: "fp_monitor_test",
		repoFullName: "fairchild/workspaces",
		prNumber: 8101,
		headSha: "abc8101def456",
		triggerKind: "opened",
		triggerSourceId: "abc8101def456",
		status,
		sessionId: "sesn_123",
		createdAt: now,
		updatedAt: now,
		error: null,
		projectionStatus:
			overrides.projectionStatus ??
			(status === "completed"
				? "projected"
				: status === "failed"
					? "failed"
					: status === "superseded"
						? "superseded"
						: "pending"),
		projectionUpdatedAt:
			overrides.projectionUpdatedAt ?? overrides.updatedAt ?? now,
		projectionError:
			overrides.projectionError ??
			(status === "failed" ? (overrides.error ?? null) : null),
		githubReviewId: null,
		...overrides,
	};
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
		mocks.listRecentPrReviewRuns.mockResolvedValue([runRow()]);

		const { GET } = await import("./route");
		const response = await GET(
			monitorRequest({ "x-workspace-webhook-canary": MONITOR_SECRET }),
		);

		expect(response.status).toBe(200);
		await expect(response.json()).resolves.toMatchObject({
			ok: true,
			checked: 1,
			eligibleEvents: 1,
			missingRuns: 0,
			executing: 1,
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
			runRow({
				fingerprint: "fp_evidence_comment",
				prNumber: 8111,
				headSha: "resolved-head-sha",
				triggerKind: "evidence_comment",
				triggerSourceId: "comment-908111",
				status: "completed",
				sessionId: "sesn_456",
			}),
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
			missingRuns: 1,
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

	it("fails the operator report when existing runs need attention", async () => {
		mocks.executeWebhookQuery.mockResolvedValue([]);
		const oldStamp = new Date(Date.now() - 45 * 60 * 1000).toISOString();
		mocks.listRecentPrReviewRuns.mockResolvedValue([
			runRow({
				fingerprint: "fp_needs_projection",
				prNumber: 9001,
				sessionId: "sesn_projection",
				updatedAt: oldStamp,
			}),
			runRow({
				fingerprint: "fp_failed",
				prNumber: 9002,
				status: "failed",
				sessionId: "sesn_failed",
				error: "review intent parse failed",
				updatedAt: oldStamp,
			}),
		]);

		const { GET } = await import("./route");
		const response = await GET(
			monitorRequest({ authorization: `Bearer ${MONITOR_SECRET}` }),
		);

		expect(response.status).toBe(503);
		await expect(response.json()).resolves.toMatchObject({
			ok: false,
			attentionRequired: 2,
			needsProjection: 1,
			failed: 1,
			runs: {
				needsProjection: [
					{
						fingerprint: "fp_needs_projection",
						state: "needs_projection",
						agentStatus: "started",
						projectionStatus: "pending",
						detailsUrl:
							"http://localhost/dashboard/review-runs/fp_needs_projection",
					},
				],
				failed: [
					{
						fingerprint: "fp_failed",
						state: "failed",
						projectionStatus: "failed",
						error: "review intent parse failed",
					},
				],
			},
		});
	});
});
