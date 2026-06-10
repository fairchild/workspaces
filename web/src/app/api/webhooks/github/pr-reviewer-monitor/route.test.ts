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
	overrides: Partial<{
		id: string;
		timestamp: string;
		payload: Record<string, unknown>;
	}> = {},
) {
	const payload = (overrides.payload ?? testCase.payload) as {
		action?: string;
	};
	return {
		id: overrides.id ?? testCase.deliveryId,
		type: testCase.eventType,
		action: String(payload.action ?? ""),
		timestamp: overrides.timestamp ?? new Date().toISOString(),
		payload: JSON.stringify(payload),
	};
}

function pullRequestPayloadFor(
	testCase: (typeof PR_REVIEW_WEBHOOK_CONTRACT_CASES)[number],
	prNumber: number,
	headSha: string,
): Record<string, unknown> {
	const payload = JSON.parse(JSON.stringify(testCase.payload)) as Record<
		string,
		unknown
	>;
	const pullRequest = payload.pull_request as Record<string, unknown>;
	pullRequest.number = prNumber;
	pullRequest.head = {
		...(pullRequest.head as Record<string, unknown>),
		sha: headSha,
	};
	return payload;
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
		sessionStartedAt: string | null;
		createdAt: string;
		updatedAt: string;
		error: string | null;
		projectionStatus: "pending" | "projected" | "failed" | "superseded";
		projectionUpdatedAt: string;
		projectionError: string | null;
		githubReviewId: string | null;
		executionState:
			| "waiting_for_session"
			| "running_session"
			| "completed"
			| "failed"
			| "superseded";
		latestKnownHeadSha: string;
		failureKind: string | null;
		failureMessage: string | null;
		failureRetryable: boolean | null;
		failedAt: string | null;
		nextAction: string;
		coalescedHeadSha: string | null;
		coalescedTriggerKind: string | null;
		coalescedTriggerSourceId: string | null;
		coalescedAt: string | null;
	}> = {},
) {
	const now = new Date().toISOString();
	const status = overrides.status ?? "started";
	const headSha = overrides.headSha ?? "abc8101def456";
	const sessionId =
		overrides.sessionId === undefined ? "sesn_123" : overrides.sessionId;
	return {
		fingerprint: "fp_monitor_test",
		repoFullName: "fairchild/workspaces",
		prNumber: 8101,
		headSha,
		triggerKind: "opened",
		triggerSourceId: "abc8101def456",
		status,
		sessionId,
		sessionStartedAt: sessionId
			? (overrides.sessionStartedAt ?? overrides.updatedAt ?? now)
			: null,
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
		executionState:
			overrides.executionState ??
			(status === "completed"
				? "completed"
				: status === "failed"
					? "failed"
					: status === "superseded"
						? "superseded"
						: sessionId
							? "running_session"
							: "waiting_for_session"),
		latestKnownHeadSha:
			overrides.latestKnownHeadSha ?? overrides.coalescedHeadSha ?? headSha,
		failureKind: null,
		failureMessage: null,
		failureRetryable: null,
		failedAt: null,
		nextAction: "",
		coalescedHeadSha: null,
		coalescedTriggerKind: null,
		coalescedTriggerSourceId: null,
		coalescedAt: null,
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
			eligibleRunKeys: 1,
			missingRuns: 0,
			missingRunKeys: 0,
			health: "healthy",
			running: 1,
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
			eligibleRunKeys: 1,
			missing: [],
		});
	});

	it("returns 503 with metadata when an eligible run key has no run row", async () => {
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
			health: "unhealthy",
			checked: 1,
			eligibleEvents: 1,
			eligibleRunKeys: 1,
			missingRuns: 1,
			missingRunKeys: 1,
			missing: [
				{
					key: "fairchild/workspaces|8101|abc8101def456",
					eventIds: ["contract-pr-opened"],
					eventCount: 1,
					repoFullName: "fairchild/workspaces",
					prNumber: 8101,
					triggerKind: "opened",
					triggerSourceId: "abc8101def456",
				},
			],
		});
	});

	it("deduplicates missing run checks by coalesced PR head key", async () => {
		const opened = PR_REVIEW_WEBHOOK_CONTRACT_CASES[0];
		mocks.executeWebhookQuery.mockResolvedValue([
			webhookRowFromContractCase(opened),
			{
				...webhookRowFromContractCase(opened),
				id: "contract-pr-opened-redelivery",
			},
		]);
		mocks.listRecentPrReviewRuns.mockResolvedValue([]);

		const { GET } = await import("./route");
		const response = await GET(
			monitorRequest({ "x-workspace-webhook-canary": MONITOR_SECRET }),
		);

		expect(response.status).toBe(503);
		await expect(response.json()).resolves.toMatchObject({
			eligibleEvents: 2,
			checked: 1,
			eligibleRunKeys: 1,
			missingRunKeys: 1,
			missing: [
				{
					eventIds: ["contract-pr-opened", "contract-pr-opened-redelivery"],
					eventCount: 2,
				},
			],
		});
	});

	it("does not report missing run keys for PRs closed after eligible triggers", async () => {
		const edited = PR_REVIEW_WEBHOOK_CONTRACT_CASES.find(
			(testCase) => testCase.deliveryId === "contract-pr-edited-body",
		);
		const closed = PR_REVIEW_WEBHOOK_CONTRACT_CASES.find(
			(testCase) => testCase.deliveryId === "contract-pr-closed",
		);
		if (!edited || !closed) throw new Error("missing PR fixtures");
		mocks.executeWebhookQuery.mockResolvedValue([
			webhookRowFromContractCase(edited, {
				id: "contract-pr-edited-before-close",
				timestamp: "2026-06-01T03:00:00.000Z",
				payload: pullRequestPayloadFor(edited, 8120, "terminalsha8120"),
			}),
			webhookRowFromContractCase(closed, {
				id: "contract-pr-closed-after-edit",
				timestamp: "2026-06-01T03:01:00.000Z",
				payload: pullRequestPayloadFor(closed, 8120, "terminalsha8120"),
			}),
		]);
		mocks.listRecentPrReviewRuns.mockResolvedValue([]);

		const { GET } = await import("./route");
		const response = await GET(
			monitorRequest({ "x-workspace-webhook-canary": MONITOR_SECRET }),
		);

		expect(response.status).toBe(200);
		await expect(response.json()).resolves.toMatchObject({
			ok: true,
			health: "healthy",
			eligibleEvents: 1,
			candidateRunKeys: 1,
			eligibleRunKeys: 0,
			terminalRunKeys: 1,
			supersededTriggerRunKeys: 0,
			missingRunKeys: 0,
			missing: [],
		});
	});

	it("reports only the latest missing trigger key for a still-open PR", async () => {
		const opened = PR_REVIEW_WEBHOOK_CONTRACT_CASES[0];
		const synchronize = PR_REVIEW_WEBHOOK_CONTRACT_CASES.find(
			(testCase) => testCase.expectedTriggerKind === "synchronize",
		);
		if (!synchronize) throw new Error("missing synchronize fixture");
		mocks.executeWebhookQuery.mockResolvedValue([
			webhookRowFromContractCase(opened, {
				timestamp: "2026-06-01T03:00:00.000Z",
				payload: pullRequestPayloadFor(opened, 8121, "oldsha8121"),
			}),
			webhookRowFromContractCase(synchronize, {
				timestamp: "2026-06-01T03:02:00.000Z",
				payload: pullRequestPayloadFor(synchronize, 8121, "newsha8121"),
			}),
		]);
		mocks.listRecentPrReviewRuns.mockResolvedValue([]);

		const { GET } = await import("./route");
		const response = await GET(
			monitorRequest({ "x-workspace-webhook-canary": MONITOR_SECRET }),
		);

		expect(response.status).toBe(503);
		await expect(response.json()).resolves.toMatchObject({
			ok: false,
			health: "unhealthy",
			eligibleEvents: 2,
			candidateRunKeys: 2,
			eligibleRunKeys: 1,
			supersededTriggerRunKeys: 1,
			missingRunKeys: 1,
			missing: [
				{
					key: "fairchild/workspaces|8121|newsha8121",
					eventIds: ["contract-pr-synchronize"],
					eventCount: 1,
					prNumber: 8121,
					triggerKind: "synchronize",
					headSha: "newsha8121",
				},
			],
		});
	});

	it("accepts a coalesced ReviewRun as covering a newer webhook head", async () => {
		const synchronize = PR_REVIEW_WEBHOOK_CONTRACT_CASES.find(
			(testCase) => testCase.expectedTriggerKind === "synchronize",
		);
		if (!synchronize) throw new Error("missing synchronize fixture");
		mocks.executeWebhookQuery.mockResolvedValue([
			webhookRowFromContractCase(synchronize),
		]);
		mocks.listRecentPrReviewRuns.mockResolvedValue([
			runRow({
				fingerprint: "fp_coalesced",
				prNumber: 8105,
				headSha: "older-head",
				coalescedHeadSha: "newsha8105abc",
				coalescedTriggerKind: "synchronize",
				coalescedTriggerSourceId: "newsha8105abc",
				coalescedAt: new Date().toISOString(),
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
			missingRunKeys: 0,
			missing: [],
		});
	});

	it("fails the operator report when existing runs need attention", async () => {
		mocks.executeWebhookQuery.mockResolvedValue([]);
		const oldStamp = new Date(Date.now() - 45 * 60 * 1000).toISOString();
		mocks.listRecentPrReviewRuns.mockResolvedValue([
			runRow({
				fingerprint: "fp_running_too_long",
				prNumber: 9001,
				sessionId: "sesn_slow",
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
			runRow({
				fingerprint: "fp_projection_failed",
				prNumber: 9003,
				status: "completed",
				sessionId: "sesn_projection_failed",
				projectionStatus: "failed",
				projectionError: "GitHub status update failed 503",
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
			health: "unhealthy",
			attentionRequired: 3,
			runningTooLong: 1,
			failedExecution: 1,
			projectionFailed: 1,
			failedRunCount: 1,
			projectionFailedCount: 1,
			githubProjectionAudit: {
				status: "not_checked",
				script: "scripts/pr-review-health.py",
			},
			runs: {
				runningTooLong: [
					{
						fingerprint: "fp_running_too_long",
						state: "running_too_long",
						agentStatus: "started",
						projectionStatus: "pending",
						detailsUrl:
							"http://localhost/dashboard/review-runs/fp_running_too_long",
					},
				],
				failedExecution: [
					{
						fingerprint: "fp_failed",
						state: "failed_execution",
						projectionStatus: "failed",
						error: "review intent parse failed",
					},
				],
				projectionFailed: [
					{
						fingerprint: "fp_projection_failed",
						state: "projection_failed",
						projectionStatus: "failed",
						projectionError: "GitHub status update failed 503",
					},
				],
			},
		});
	});

	it("reports stale projection and superseded runs without collapsing them into GitHub drift", async () => {
		mocks.executeWebhookQuery.mockResolvedValue([]);
		const projectionStamp = new Date(Date.now() - 45 * 60 * 1000).toISOString();
		mocks.listRecentPrReviewRuns.mockResolvedValue([
			runRow({
				fingerprint: "fp_awaiting_projection",
				status: "completed",
				sessionId: "sesn_completed",
				projectionStatus: "pending",
				projectionUpdatedAt: projectionStamp,
			}),
			runRow({
				fingerprint: "fp_superseded",
				status: "superseded",
				sessionId: "sesn_superseded",
				projectionStatus: "superseded",
			}),
		]);

		const { GET } = await import("./route");
		const response = await GET(
			monitorRequest({ authorization: `Bearer ${MONITOR_SECRET}` }),
		);

		expect(response.status).toBe(503);
		await expect(response.json()).resolves.toMatchObject({
			completedAwaitingProjection: 1,
			superseded: 1,
			staleRunCount: 1,
			supersededRunCount: 1,
			staleOrSupersededCount: 2,
			reviewRunHealth: {
				status: "unhealthy",
				staleRunCount: 1,
				supersededRunCount: 1,
			},
			githubProjectionAudit: {
				status: "not_checked",
			},
			runs: {
				completedAwaitingProjection: [
					{
						fingerprint: "fp_awaiting_projection",
						state: "completed_awaiting_projection",
						projectionLatencyMinutes: expect.any(Number),
						sloBreached: true,
					},
				],
				superseded: [
					{
						fingerprint: "fp_superseded",
						state: "superseded",
					},
				],
			},
		});
	});
});
