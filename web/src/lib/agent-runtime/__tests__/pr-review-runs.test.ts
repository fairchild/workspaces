import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Use a unique in-memory libsql DB per test process so the schema bootstrap
// runs against a real engine without persisting between runs.
beforeEach(() => {
	vi.stubEnv("TURSO_DATABASE_URL", ":memory:");
});

afterEach(() => {
	vi.unstubAllEnvs();
	vi.resetModules();
});

async function loadModule() {
	vi.resetModules();
	const mod = await import("../pr-review-runs");
	mod.__resetPrReviewRunsForTests();
	return mod;
}

interface RunInput {
	fingerprint: string;
	repoFullName: string;
	prNumber: number;
	headSha: string;
	triggerKind: string;
	triggerSourceId: string;
	reviewerConfigHash: string;
}

function makeInput(overrides: Partial<RunInput> = {}): RunInput {
	return {
		fingerprint: "fp_unit_test",
		repoFullName: "fairchild/workspaces",
		prNumber: 1,
		headSha: "abc123",
		triggerKind: "synchronize",
		triggerSourceId: "abc123",
		reviewerConfigHash: "cfg",
		...overrides,
	};
}

describe("recordRunStart", () => {
	it("inserts on first call and skips a fresh duplicate", async () => {
		const { recordRunStart } = await loadModule();
		const input = makeInput();

		const first = await recordRunStart(input);
		expect(first.inserted).toBe(true);

		const second = await recordRunStart(input);
		expect(second.inserted).toBe(false);
	});

	it("coalesces a different active fingerprint for the same PR and reviewer config", async () => {
		const { getPrReviewRunByFingerprint, recordRunStart } = await loadModule();
		const active = makeInput({
			fingerprint: "fp_active",
			headSha: "head-a",
			triggerKind: "synchronize",
			triggerSourceId: "head-a",
		});
		const newer = makeInput({
			fingerprint: "fp_newer",
			headSha: "head-b",
			triggerKind: "edited",
			triggerSourceId: "body-new",
		});

		await expect(recordRunStart(active)).resolves.toEqual({ inserted: true });
		const coalesced = await recordRunStart(newer);

		expect(coalesced).toMatchObject({
			inserted: false,
			coalesced: true,
			activeFingerprint: "fp_active",
			priorStatus: "started",
		});
		const row = await getPrReviewRunByFingerprint("fp_active");
		expect(row).toMatchObject({
			coalescedHeadSha: "head-b",
			coalescedTriggerKind: "edited",
			coalescedTriggerSourceId: "body-new",
		});
		expect(row?.coalescedAt).toEqual(expect.any(String));
	});

	it("keeps only the latest synchronize trigger while a run is active", async () => {
		const { getPrReviewRunByFingerprint, recordRunStart } = await loadModule();
		const active = makeInput({
			fingerprint: "fp_active_sync",
			headSha: "head-a",
			triggerKind: "opened",
			triggerSourceId: "head-a",
		});
		const firstPush = makeInput({
			fingerprint: "fp_sync_head_b",
			headSha: "head-b",
			triggerKind: "synchronize",
			triggerSourceId: "head-b",
		});
		const secondPush = makeInput({
			fingerprint: "fp_sync_head_c",
			headSha: "head-c",
			triggerKind: "synchronize",
			triggerSourceId: "head-c",
		});

		await expect(recordRunStart(active)).resolves.toEqual({ inserted: true });
		await expect(recordRunStart(firstPush)).resolves.toMatchObject({
			inserted: false,
			coalesced: true,
			activeFingerprint: active.fingerprint,
		});
		await expect(recordRunStart(secondPush)).resolves.toMatchObject({
			inserted: false,
			coalesced: true,
			activeFingerprint: active.fingerprint,
		});

		await expect(
			getPrReviewRunByFingerprint(active.fingerprint),
		).resolves.toMatchObject({
			coalescedHeadSha: "head-c",
			coalescedTriggerKind: "synchronize",
			coalescedTriggerSourceId: "head-c",
		});
	});

	it("clears the active claim when a run reaches a terminal state", async () => {
		const { recordRunStart, recordRunResult } = await loadModule();
		const first = makeInput({
			fingerprint: "fp_first",
			headSha: "head-a",
			triggerSourceId: "head-a",
		});
		const second = makeInput({
			fingerprint: "fp_second",
			headSha: "head-b",
			triggerSourceId: "head-b",
		});

		await recordRunStart(first);
		await recordRunResult(first.fingerprint, {
			sessionId: "sesn_first",
			status: "completed",
		});

		const next = await recordRunStart(second);
		expect(next).toEqual({ inserted: true });
	});

	it("can release an active claim without changing the run status", async () => {
		const { releaseRunActiveClaim, recordRunStart } = await loadModule();
		const active = makeInput({
			fingerprint: "fp_claim_release",
			headSha: "head-a",
			triggerSourceId: "head-a",
		});
		const followUp = makeInput({
			fingerprint: "fp_after_release",
			headSha: "head-b",
			triggerSourceId: "head-b",
		});

		await recordRunStart(active);
		await releaseRunActiveClaim(active.fingerprint);

		await expect(recordRunStart(followUp)).resolves.toEqual({
			inserted: true,
		});
	});

	it("does not coalesce across different reviewer config hashes", async () => {
		const { recordRunStart } = await loadModule();
		const first = makeInput({
			fingerprint: "fp_cfg_a",
			reviewerConfigHash: "cfg-a",
		});
		const second = makeInput({
			fingerprint: "fp_cfg_b",
			reviewerConfigHash: "cfg-b",
		});

		await expect(recordRunStart(first)).resolves.toEqual({ inserted: true });
		await expect(recordRunStart(second)).resolves.toEqual({ inserted: true });
	});

	it("releases a stale active claim so a newer fingerprint can start", async () => {
		const { getPrReviewRunByFingerprint, recordRunStart } = await loadModule();
		const stale = makeInput({
			fingerprint: "fp_stale_active",
			headSha: "head-a",
			triggerSourceId: "head-a",
		});
		const newer = makeInput({
			fingerprint: "fp_after_stale",
			headSha: "head-b",
			triggerSourceId: "head-b",
		});

		await recordRunStart(stale);
		const { getDb } = await import("../../db");
		const oldStamp = new Date(Date.now() - 30 * 60 * 1000).toISOString();
		await getDb()
			.updateTable("managed_pr_review_runs")
			.set({ updated_at: oldStamp })
			.where("fingerprint", "=", stale.fingerprint)
			.execute();

		await expect(recordRunStart(newer)).resolves.toEqual({ inserted: true });
		await expect(
			getPrReviewRunByFingerprint(stale.fingerprint),
		).resolves.toMatchObject({
			status: "superseded",
			projectionStatus: "superseded",
			error: expect.stringContaining("active claim became stale"),
		});
	});

	it("treats a completed prior run as a permanent skip", async () => {
		const { recordRunStart, recordRunResult } = await loadModule();
		const input = makeInput();

		await recordRunStart(input);
		await recordRunResult(input.fingerprint, {
			sessionId: "sesn_done",
			status: "completed",
		});

		const retry = await recordRunStart(input);
		expect(retry.inserted).toBe(false);
		expect(retry.priorStatus).toBe("completed");
	});

	it("treats a superseded prior run as a permanent skip", async () => {
		const { recordRunStart, recordRunResult } = await loadModule();
		const input = makeInput();

		await recordRunStart(input);
		await recordRunResult(input.fingerprint, {
			sessionId: "sesn_old",
			status: "superseded",
			error: "newer review already posted",
		});

		const retry = await recordRunStart(input);
		expect(retry.inserted).toBe(false);
		expect(retry.priorStatus).toBe("superseded");
	});

	it("retries when the prior run failed", async () => {
		const { recordRunStart, recordRunResult } = await loadModule();
		const input = makeInput();

		await recordRunStart(input);
		await recordRunResult(input.fingerprint, {
			sessionId: null,
			status: "failed",
			error: "session denied",
		});

		const retry = await recordRunStart(input);
		expect(retry.inserted).toBe(true);
		expect(retry.priorStatus).toBe("failed");
	});

	it("coalesces a failed exact-fingerprint retry if a different run is already active", async () => {
		const { getPrReviewRunByFingerprint, recordRunStart, recordRunResult } =
			await loadModule();
		const failed = makeInput({
			fingerprint: "fp_failed_exact",
			headSha: "head-a",
			triggerSourceId: "head-a",
		});
		const active = makeInput({
			fingerprint: "fp_active_other",
			headSha: "head-b",
			triggerSourceId: "head-b",
		});

		await recordRunStart(failed);
		await recordRunResult(failed.fingerprint, {
			sessionId: null,
			status: "failed",
			error: "session failed before kickoff",
		});
		await expect(recordRunStart(active)).resolves.toEqual({ inserted: true });

		const retry = await recordRunStart(failed);

		expect(retry).toMatchObject({
			inserted: false,
			coalesced: true,
			activeFingerprint: active.fingerprint,
			priorStatus: "started",
		});
		await expect(
			getPrReviewRunByFingerprint(active.fingerprint),
		).resolves.toMatchObject({
			coalescedHeadSha: "head-a",
			coalescedTriggerSourceId: "head-a",
		});
	});

	it("retries when a prior `started` row is stale (likely crashed)", async () => {
		const { recordRunStart } = await loadModule();
		const input = makeInput();

		await recordRunStart(input);

		// Force the row's updated_at to be older than the stale threshold.
		const { getDb } = await import("../../db");
		const oldStamp = new Date(Date.now() - 30 * 60 * 1000).toISOString();
		await getDb()
			.updateTable("managed_pr_review_runs")
			.set({ updated_at: oldStamp })
			.where("fingerprint", "=", input.fingerprint)
			.execute();

		const retry = await recordRunStart(input);
		expect(retry.inserted).toBe(true);
		expect(retry.priorStatus).toBe("started");
	});
});

describe("listStartedPrReviewRuns", () => {
	it("returns only started rows with a session id in oldest-first order", async () => {
		const { listStartedPrReviewRuns, recordRunStart, recordRunResult } =
			await loadModule();
		const started = makeInput({
			fingerprint: "fp_started",
			prNumber: 1,
			headSha: "started-sha",
		});
		const completed = makeInput({
			fingerprint: "fp_completed",
			prNumber: 2,
			headSha: "completed-sha",
		});
		const noSession = makeInput({
			fingerprint: "fp_no_session",
			prNumber: 3,
			headSha: "no-session-sha",
		});

		await recordRunStart(started);
		await recordRunResult(started.fingerprint, {
			sessionId: "sesn_started",
			status: "started",
		});
		await recordRunStart(completed);
		await recordRunResult(completed.fingerprint, {
			sessionId: "sesn_completed",
			status: "completed",
		});
		await recordRunStart(noSession);

		const rows = await listStartedPrReviewRuns();

		expect(rows).toHaveLength(1);
		expect(rows[0]).toMatchObject({
			fingerprint: "fp_started",
			prNumber: 1,
			sessionId: "sesn_started",
		});
	});
});

describe("listPrReviewRunsForBroker", () => {
	it("returns active sessions and completed runs that still need projection", async () => {
		const {
			getPrReviewRunByFingerprint,
			listPrReviewRunsForBroker,
			recordRunStart,
			recordRunResult,
		} = await loadModule();
		const started = makeInput({
			fingerprint: "fp_broker_started",
			prNumber: 10,
		});
		const repair = makeInput({
			fingerprint: "fp_broker_repair",
			prNumber: 11,
		});
		const missingIntent = makeInput({
			fingerprint: "fp_broker_missing_intent",
			prNumber: 12,
		});
		const projected = makeInput({
			fingerprint: "fp_broker_projected",
			prNumber: 13,
		});

		await recordRunStart(started);
		await recordRunResult(started.fingerprint, {
			sessionId: "sesn_started",
			status: "started",
		});
		await recordRunStart(repair);
		await recordRunResult(repair.fingerprint, {
			sessionId: "sesn_repair",
			status: "completed",
			projectionStatus: "failed",
			projectionError: "GitHub status update failed 503",
			reviewIntent: {
				event: "COMMENT",
				body: "Persisted review body.",
				labels: ["refactor"],
			},
		});
		await recordRunStart(missingIntent);
		await recordRunResult(missingIntent.fingerprint, {
			sessionId: "sesn_missing",
			status: "completed",
			projectionStatus: "failed",
			projectionError: "missing persisted intent",
		});
		await recordRunStart(projected);
		await recordRunResult(projected.fingerprint, {
			sessionId: "sesn_projected",
			status: "completed",
		});

		const rows = await listPrReviewRunsForBroker();

		expect(rows.map((row) => row.fingerprint).sort()).toEqual([
			"fp_broker_missing_intent",
			"fp_broker_repair",
			"fp_broker_started",
		]);
		expect(
			rows.find((row) => row.fingerprint === repair.fingerprint),
		).toMatchObject({
			status: "completed",
			projectionStatus: "failed",
			reviewIntent: {
				event: "COMMENT",
				body: "Persisted review body.",
				labels: ["refactor"],
			},
		});
		await expect(
			getPrReviewRunByFingerprint(repair.fingerprint),
		).resolves.toMatchObject({
			status: "completed",
			projectionStatus: "failed",
			reviewIntent: {
				event: "COMMENT",
				body: "Persisted review body.",
				labels: ["refactor"],
			},
		});
	});
});

describe("projection ledger", () => {
	it("hashes desired payloads stably and records successful projection state", async () => {
		const {
			beginPrReviewProjectionAttempt,
			listPrReviewProjectionsForRun,
			recordPrReviewProjectionSuccess,
		} = await loadModule();

		const first = await beginPrReviewProjectionAttempt({
			runFingerprint: "fp_projection_hash",
			type: "github_status",
			projectionKey: "WorkSpaces Managed Review",
			desiredPayload: { state: "success", description: "done" },
		});
		await recordPrReviewProjectionSuccess(first.projectionId, {
			observedExternalId: "status-1",
		});
		await recordPrReviewProjectionSuccess(first.projectionId);
		const duplicate = await beginPrReviewProjectionAttempt({
			runFingerprint: "fp_projection_hash",
			type: "github_status",
			projectionKey: "WorkSpaces Managed Review",
			desiredPayload: { description: "done", state: "success" },
		});

		expect(duplicate).toMatchObject({
			projectionId: first.projectionId,
			desiredPayloadHash: first.desiredPayloadHash,
			shouldProject: false,
			attempts: 1,
			state: "projected",
			observedExternalId: "status-1",
		});
		await expect(
			listPrReviewProjectionsForRun("fp_projection_hash"),
		).resolves.toMatchObject([
			{
				type: "github_status",
				state: "projected",
				attempts: 1,
				observedExternalId: "status-1",
			},
		]);
	});

	it("retries failed desired projections without creating duplicate records", async () => {
		const {
			beginPrReviewProjectionAttempt,
			listPrReviewProjectionsForRun,
			recordPrReviewProjectionFailure,
		} = await loadModule();
		const input = {
			runFingerprint: "fp_projection_retry",
			type: "github_review" as const,
			projectionKey: "final-review",
			desiredPayload: { event: "COMMENT", body: "retry me", labels: [] },
		};

		const first = await beginPrReviewProjectionAttempt(input);
		await recordPrReviewProjectionFailure(first.projectionId, {
			errorKind: "transient_api",
			errorText: "GitHub review post failed 503: temporarily unavailable",
		});
		const retry = await beginPrReviewProjectionAttempt(input);

		expect(retry).toMatchObject({
			projectionId: first.projectionId,
			shouldProject: true,
			attempts: 2,
			state: "projecting",
		});
		const records = await listPrReviewProjectionsForRun("fp_projection_retry");
		expect(records).toHaveLength(1);
		expect(records[0]).toMatchObject({
			state: "projecting",
			attempts: 2,
			errorKind: null,
			errorText: null,
		});
	});

	it("stores bounded redacted projection errors with classified context", async () => {
		const {
			beginPrReviewProjectionAttempt,
			classifyPrReviewProjectionError,
			listPrReviewProjectionsForRun,
			recordPrReviewProjectionFailure,
		} = await loadModule();
		const secret = `ghp_${"a".repeat(40)}`;
		const attempt = await beginPrReviewProjectionAttempt({
			runFingerprint: "fp_projection_error",
			type: "github_status",
			projectionKey: "WorkSpaces Managed Review",
			desiredPayload: { state: "failure", description: "failed" },
		});

		await recordPrReviewProjectionFailure(attempt.projectionId, {
			errorKind: classifyPrReviewProjectionError({
				status: 403,
				message: `forbidden ${secret}`,
			}),
			errorText: `GitHub status update failed 403: forbidden ${secret} ${"x".repeat(900)}`,
		});

		const [record] = await listPrReviewProjectionsForRun("fp_projection_error");
		expect(record).toMatchObject({
			state: "failed",
			attempts: 1,
			errorKind: "auth",
		});
		expect(record.errorText).not.toContain(secret);
		expect(record.errorText).toContain("[redacted]");
		expect(record.errorText?.length).toBeLessThanOrEqual(603);
	});

	it("classifies projection API failures into operator-safe buckets", async () => {
		const { classifyPrReviewProjectionError } = await loadModule();

		expect(
			classifyPrReviewProjectionError({ status: 401, message: "bad token" }),
		).toBe("auth");
		expect(
			classifyPrReviewProjectionError({
				status: 429,
				message: "secondary rate limit",
			}),
		).toBe("rate_limit");
		expect(
			classifyPrReviewProjectionError({
				status: 503,
				message: "temporarily unavailable",
			}),
		).toBe("transient_api");
		expect(
			classifyPrReviewProjectionError({
				status: 422,
				message: "validation failed",
			}),
		).toBe("validation");
		expect(
			classifyPrReviewProjectionError({ status: 418, message: "teapot" }),
		).toBe("unknown");
	});

	it("does not expose secrets, raw webhook payloads, or unbounded managed output", async () => {
		const { beginPrReviewProjectionAttempt, listPrReviewProjectionsForRun } =
			await loadModule();
		const secret = `github_pat_${"b".repeat(40)}`;

		await beginPrReviewProjectionAttempt({
			runFingerprint: "fp_projection_security",
			type: "github_review",
			projectionKey: "final-review",
			desiredPayload: {
				event: "COMMENT",
				body: `${secret} ${"managed output ".repeat(600)}`,
				rawWebhookPayload: { token: secret, action: "synchronize" },
				authorizationToken: secret,
			},
		});

		const [record] = await listPrReviewProjectionsForRun(
			"fp_projection_security",
		);
		const serialized = JSON.stringify(record.desiredPayload);
		expect(serialized).not.toContain(secret);
		expect(serialized).not.toContain("github_pat_");
		expect(serialized).not.toContain("synchronize");
		expect(serialized.length).toBeLessThanOrEqual(4096);
		expect(
			String((record.desiredPayload as { body: string }).body).length,
		).toBeLessThanOrEqual(1002);
		expect(serialized).toContain("[redacted]");
	});
});

describe("bucketPrReviewRuns", () => {
	it("separates ReviewRun health by execution and projection state with SLO latencies", async () => {
		const { bucketPrReviewRuns } = await loadModule();
		const now = new Date("2026-05-24T12:00:00.000Z");
		const base = {
			repoFullName: "fairchild/workspaces",
			prNumber: 1,
			headSha: "abc123",
			triggerKind: "opened",
			triggerSourceId: "abc123",
			error: null,
			projectionError: null,
			githubReviewId: null,
			reviewIntent: null,
			coalescedHeadSha: null,
			coalescedTriggerKind: null,
			coalescedTriggerSourceId: null,
			coalescedAt: null,
		};
		const pendingRun = (overrides: {
			fingerprint: string;
			status: "started" | "completed" | "failed" | "superseded";
			sessionId: string | null;
			createdAt: string;
			updatedAt: string;
			error?: string | null;
			projectionStatus?: "pending" | "projected" | "failed" | "superseded";
			projectionUpdatedAt?: string;
			projectionError?: string | null;
		}) => ({
			...base,
			executionState:
				overrides.status === "completed"
					? ("completed" as const)
					: overrides.status === "failed"
						? ("failed" as const)
						: overrides.status === "superseded"
							? ("superseded" as const)
							: overrides.sessionId
								? ("running_session" as const)
								: ("waiting_for_session" as const),
			latestKnownHeadSha: base.headSha,
			failureKind: null,
			failureMessage: null,
			failureRetryable: null,
			failedAt: null,
			nextAction: "",
			projectionStatus: overrides.projectionStatus ?? ("pending" as const),
			projectionUpdatedAt: overrides.projectionUpdatedAt ?? overrides.updatedAt,
			...overrides,
		});

		const buckets = bucketPrReviewRuns(
			[
				pendingRun({
					fingerprint: "fp_starting",
					status: "started" as const,
					sessionId: null,
					createdAt: "2026-05-24T11:59:00.000Z",
					updatedAt: "2026-05-24T11:59:00.000Z",
				}),
				pendingRun({
					fingerprint: "fp_stuck_starting",
					status: "started" as const,
					sessionId: null,
					createdAt: "2026-05-24T11:50:00.000Z",
					updatedAt: "2026-05-24T11:50:00.000Z",
				}),
				pendingRun({
					fingerprint: "fp_running",
					status: "started" as const,
					sessionId: "sesn_running",
					createdAt: "2026-05-24T11:35:00.000Z",
					updatedAt: "2026-05-24T11:40:00.000Z",
				}),
				pendingRun({
					fingerprint: "fp_running_too_long",
					status: "started" as const,
					sessionId: "sesn_slow",
					createdAt: "2026-05-24T11:00:00.000Z",
					updatedAt: "2026-05-24T11:20:00.000Z",
				}),
				pendingRun({
					fingerprint: "fp_completed_awaiting_projection",
					status: "completed" as const,
					sessionId: "sesn_completed",
					createdAt: "2026-05-24T11:00:00.000Z",
					updatedAt: "2026-05-24T11:35:00.000Z",
					projectionStatus: "pending",
					projectionUpdatedAt: "2026-05-24T11:45:00.000Z",
				}),
				pendingRun({
					fingerprint: "fp_failed",
					status: "failed" as const,
					sessionId: "sesn_failed",
					createdAt: "2026-05-24T11:50:00.000Z",
					updatedAt: "2026-05-24T11:58:00.000Z",
					error: "review intent parse failed",
					projectionStatus: "failed",
					projectionError: "review intent parse failed",
				}),
				pendingRun({
					fingerprint: "fp_projection_failed",
					status: "completed" as const,
					sessionId: "sesn_projection_failed",
					createdAt: "2026-05-24T11:10:00.000Z",
					updatedAt: "2026-05-24T11:40:00.000Z",
					projectionStatus: "failed",
					projectionError: "GitHub status update failed 503",
				}),
				pendingRun({
					fingerprint: "fp_superseded",
					status: "superseded" as const,
					sessionId: "sesn_superseded",
					createdAt: "2026-05-24T11:05:00.000Z",
					updatedAt: "2026-05-24T11:55:00.000Z",
					projectionStatus: "superseded",
				}),
				pendingRun({
					fingerprint: "fp_published",
					status: "completed" as const,
					sessionId: "sesn_published",
					createdAt: "2026-05-24T11:05:00.000Z",
					updatedAt: "2026-05-24T11:58:00.000Z",
					projectionStatus: "projected",
				}),
			],
			{
				now,
				thresholds: {
					startingTimeoutMinutes: 5,
					runningTimeoutMinutes: 30,
					projectionTimeoutMinutes: 30,
				},
			},
		);

		expect(buckets.starting.map((run) => run.fingerprint)).toEqual([
			"fp_starting",
		]);
		expect(buckets.stuckStarting.map((run) => run.fingerprint)).toEqual([
			"fp_stuck_starting",
		]);
		expect(buckets.running.map((run) => run.fingerprint)).toEqual([
			"fp_running",
		]);
		expect(buckets.runningTooLong.map((run) => run.fingerprint)).toEqual([
			"fp_running_too_long",
		]);
		expect(
			buckets.completedAwaitingProjection.map((run) => run.fingerprint),
		).toEqual(["fp_completed_awaiting_projection"]);
		expect(buckets.failedExecution.map((run) => run.fingerprint)).toEqual([
			"fp_failed",
		]);
		expect(buckets.projectionFailed.map((run) => run.fingerprint)).toEqual([
			"fp_projection_failed",
		]);
		expect(buckets.superseded.map((run) => run.fingerprint)).toEqual([
			"fp_superseded",
		]);
		expect(buckets.published.map((run) => run.fingerprint)).toEqual([
			"fp_published",
		]);
		expect(buckets.runningTooLong[0]).toMatchObject({
			ageMinutes: 40,
			pickupLatencyMinutes: 20,
			executionDurationMinutes: 40,
			projectionLatencyMinutes: null,
			sloBreached: true,
		});
		expect(buckets.completedAwaitingProjection[0]).toMatchObject({
			ageMinutes: 15,
			projectionLatencyMinutes: 15,
			sloBreached: false,
		});
	});
});

describe("run detail lookups", () => {
	it("uses transition helpers for valid lifecycle transitions", async () => {
		const {
			getPrReviewRunByFingerprint,
			markRunCompleted,
			markRunSessionStarted,
			recordRunStart,
		} = await loadModule();
		const input = makeInput({ fingerprint: "fp_lifecycle", prNumber: 44 });

		await recordRunStart(input);
		await markRunSessionStarted(input.fingerprint, {
			sessionId: "sesn_lifecycle",
		});
		await markRunCompleted(input.fingerprint, {
			sessionId: "sesn_lifecycle",
			githubReviewId: "9876",
		});

		await expect(
			getPrReviewRunByFingerprint(input.fingerprint),
		).resolves.toMatchObject({
			status: "completed",
			executionState: "completed",
			projectionStatus: "projected",
			githubReviewId: "9876",
			failureKind: null,
			nextAction:
				"No action needed; the ReviewRun has been published to GitHub.",
		});
	});

	it("allows unpublished completed runs to be superseded during repair", async () => {
		const {
			getPrReviewRunByFingerprint,
			markRunCompleted,
			markRunSuperseded,
			recordRunStart,
		} = await loadModule();
		const input = makeInput({
			fingerprint: "fp_unpublished_completed_supersede",
		});

		await recordRunStart(input);
		await markRunCompleted(input.fingerprint, {
			sessionId: "sesn_unpublished_completed",
			projectionStatus: "failed",
			projectionError: "GitHub status update failed 503",
		});
		await markRunSuperseded(input.fingerprint, {
			sessionId: "sesn_unpublished_completed",
			reason: "PR head moved before projection could be repaired.",
		});

		await expect(
			getPrReviewRunByFingerprint(input.fingerprint),
		).resolves.toMatchObject({
			status: "superseded",
			projectionStatus: "superseded",
			error: "PR head moved before projection could be repaired.",
			nextAction:
				"No action needed for this run; a newer run or review replaced it.",
		});
	});

	it("blocks lifecycle transitions away from a terminal state", async () => {
		const {
			markRunCompleted,
			markRunFailed,
			markRunSuperseded,
			recordRunStart,
		} = await loadModule();
		const input = makeInput({ fingerprint: "fp_terminal_guard" });

		await recordRunStart(input);
		await markRunCompleted(input.fingerprint, {
			sessionId: "sesn_terminal",
		});

		await expect(
			markRunFailed(input.fingerprint, {
				sessionId: "sesn_terminal",
				error: "late failure",
			}),
		).rejects.toThrow("is terminal");
		await expect(
			markRunSuperseded(input.fingerprint, {
				sessionId: "sesn_terminal",
				reason: "late supersede",
			}),
		).rejects.toThrow("is terminal");
	});

	it("persists bounded user-safe failure details", async () => {
		const { getPrReviewRunByFingerprint, markRunFailed, recordRunStart } =
			await loadModule();
		const input = makeInput({ fingerprint: "fp_failure_details" });
		const secret = `github_pat_${"a".repeat(40)}`;
		const longError = `review intent parse failed with ${secret} ${"x".repeat(900)}`;

		await recordRunStart(input);
		await markRunFailed(input.fingerprint, {
			sessionId: "sesn_failure",
			error: longError,
		});

		const run = await getPrReviewRunByFingerprint(input.fingerprint);
		expect(run).toMatchObject({
			status: "failed",
			executionState: "failed",
			failureKind: "review_intent_invalid",
			failureRetryable: false,
			projectionStatus: "failed",
		});
		expect(run?.failedAt).toEqual(expect.any(String));
		expect(run?.failureMessage).not.toContain(secret);
		expect(run?.failureMessage).toContain("[redacted]");
		expect(run?.failureMessage?.length).toBeLessThanOrEqual(602);
		expect(run?.nextAction).toBe("Manual inspection required before retry.");
	});

	it("returns run details by fingerprint and session id", async () => {
		const {
			getPrReviewRunByFingerprint,
			getPrReviewRunBySessionId,
			recordRunStart,
			recordRunResult,
		} = await loadModule();
		const input = makeInput({ fingerprint: "fp_details", prNumber: 42 });

		await recordRunStart(input);
		await recordRunResult(input.fingerprint, {
			sessionId: "sesn_details",
			status: "failed",
			error: "review intent parse failed",
		});

		await expect(getPrReviewRunByFingerprint("missing")).resolves.toBeNull();
		const byFingerprint = await getPrReviewRunByFingerprint(input.fingerprint);
		const bySession = await getPrReviewRunBySessionId("sesn_details");

		expect(byFingerprint).toMatchObject({
			fingerprint: "fp_details",
			repoFullName: "fairchild/workspaces",
			prNumber: 42,
			sessionId: "sesn_details",
			status: "failed",
			error: "review intent parse failed",
			executionState: "failed",
			latestKnownHeadSha: "abc123",
			failureKind: "review_intent_invalid",
			failureMessage: "review intent parse failed",
			failureRetryable: false,
			failedAt: expect.any(String),
			projectionStatus: "failed",
			projectionError: "review intent parse failed",
		});
		expect(bySession).toEqual(byFingerprint);
	});
});
