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

describe("bucketPrReviewRuns", () => {
	it("separates runs that are starting, executing, due for projection, failed, and terminal", async () => {
		const { bucketPrReviewRuns } = await loadModule();
		const now = new Date("2026-05-24T12:00:00.000Z");
		const base = {
			repoFullName: "fairchild/workspaces",
			prNumber: 1,
			headSha: "abc123",
			triggerKind: "opened",
			triggerSourceId: "abc123",
			createdAt: "2026-05-24T11:00:00.000Z",
			error: null,
			projectionError: null,
			githubReviewId: null,
			coalescedHeadSha: null,
			coalescedTriggerKind: null,
			coalescedTriggerSourceId: null,
			coalescedAt: null,
		};
		const pendingRun = (overrides: {
			fingerprint: string;
			status: "started" | "completed" | "failed";
			sessionId: string | null;
			updatedAt: string;
			error?: string | null;
			projectionStatus?: "pending" | "projected" | "failed";
			projectionError?: string | null;
		}) => ({
			...base,
			projectionStatus: overrides.projectionStatus ?? ("pending" as const),
			projectionUpdatedAt: overrides.updatedAt,
			...overrides,
		});

		const buckets = bucketPrReviewRuns(
			[
				pendingRun({
					fingerprint: "fp_starting",
					status: "started" as const,
					sessionId: null,
					updatedAt: "2026-05-24T11:59:00.000Z",
				}),
				pendingRun({
					fingerprint: "fp_stuck_starting",
					status: "started" as const,
					sessionId: null,
					updatedAt: "2026-05-24T11:50:00.000Z",
				}),
				pendingRun({
					fingerprint: "fp_executing",
					status: "started" as const,
					sessionId: "sesn_executing",
					updatedAt: "2026-05-24T11:40:00.000Z",
				}),
				pendingRun({
					fingerprint: "fp_needs_projection",
					status: "started" as const,
					sessionId: "sesn_projection",
					updatedAt: "2026-05-24T11:20:00.000Z",
				}),
				pendingRun({
					fingerprint: "fp_failed",
					status: "failed" as const,
					sessionId: "sesn_failed",
					updatedAt: "2026-05-24T11:58:00.000Z",
					error: "review intent parse failed",
					projectionStatus: "failed",
					projectionError: "review intent parse failed",
				}),
				pendingRun({
					fingerprint: "fp_completed",
					status: "completed" as const,
					sessionId: "sesn_completed",
					updatedAt: "2026-05-24T11:58:00.000Z",
					projectionStatus: "projected",
				}),
			],
			{
				now,
				thresholds: {
					startingTimeoutMinutes: 5,
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
		expect(buckets.executing.map((run) => run.fingerprint)).toEqual([
			"fp_executing",
		]);
		expect(buckets.needsProjection.map((run) => run.fingerprint)).toEqual([
			"fp_needs_projection",
		]);
		expect(buckets.failed.map((run) => run.fingerprint)).toEqual(["fp_failed"]);
		expect(buckets.terminal.map((run) => run.fingerprint)).toEqual([
			"fp_completed",
		]);
		expect(buckets.needsProjection[0].ageMinutes).toBe(40);
	});
});

describe("run detail lookups", () => {
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
			projectionStatus: "failed",
			projectionError: "review intent parse failed",
		});
		expect(bySession).toEqual(byFingerprint);
	});
});
