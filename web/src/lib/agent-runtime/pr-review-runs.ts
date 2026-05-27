import { createHash } from "node:crypto";
import { getDb } from "../db";

export type PrReviewRunStatus =
	| "started"
	| "completed"
	| "failed"
	| "superseded";

export type PrReviewProjectionStatus =
	| "pending"
	| "projected"
	| "failed"
	| "superseded";

export interface PrReviewRunFingerprintInput {
	repoFullName: string;
	prNumber: number;
	headSha: string;
	triggerKind: string;
	triggerSourceId: string;
	reviewerConfigHash: string;
}

export interface PrReviewRunRecordInput extends PrReviewRunFingerprintInput {
	fingerprint: string;
}

let migrated = false;

async function ensureRunsTable(): Promise<void> {
	if (migrated) return;
	const db = getDb();
	await db.schema
		.createTable("managed_pr_review_runs")
		.ifNotExists()
		.addColumn("fingerprint", "text", (c) => c.primaryKey())
		.addColumn("repo_full_name", "text", (c) => c.notNull())
		.addColumn("pr_number", "integer", (c) => c.notNull())
		.addColumn("head_sha", "text", (c) => c.notNull())
		.addColumn("trigger_kind", "text", (c) => c.notNull())
		.addColumn("trigger_source_id", "text", (c) => c.notNull())
		.addColumn("reviewer_config_hash", "text", (c) => c.notNull())
		.addColumn("session_id", "text")
		.addColumn("status", "text", (c) => c.notNull())
		.addColumn("created_at", "text", (c) => c.notNull())
		.addColumn("updated_at", "text", (c) => c.notNull())
		.addColumn("error", "text")
		.addColumn("projection_status", "text")
		.addColumn("projection_updated_at", "text")
		.addColumn("projection_error", "text")
		.addColumn("github_review_id", "text")
		.addColumn("active_claim_key", "text")
		.addColumn("coalesced_head_sha", "text")
		.addColumn("coalesced_trigger_kind", "text")
		.addColumn("coalesced_trigger_source_id", "text")
		.addColumn("coalesced_at", "text")
		.execute();
	for (const [column, type] of [
		["projection_status", "text"],
		["projection_updated_at", "text"],
		["projection_error", "text"],
		["github_review_id", "text"],
		["active_claim_key", "text"],
		["coalesced_head_sha", "text"],
		["coalesced_trigger_kind", "text"],
		["coalesced_trigger_source_id", "text"],
		["coalesced_at", "text"],
	] as const) {
		try {
			await db.schema
				.alterTable("managed_pr_review_runs")
				.addColumn(column, type)
				.execute();
		} catch {
			// Column already exists.
		}
	}
	await db.schema
		.createIndex("idx_managed_pr_review_runs_pr")
		.ifNotExists()
		.on("managed_pr_review_runs")
		.columns(["repo_full_name", "pr_number"])
		.execute();
	// New rows hold this nullable unique value only while active. Existing
	// pre-migration `started` rows are intentionally not backfilled; they age out
	// through the normal stale-started path rather than risking a broad migration.
	await db.schema
		.createIndex("ux_managed_pr_review_runs_active_claim")
		.ifNotExists()
		.on("managed_pr_review_runs")
		.column("active_claim_key")
		.unique()
		.execute();
	migrated = true;
}

export function computeRunFingerprint(
	input: PrReviewRunFingerprintInput,
): string {
	const payload = [
		input.repoFullName,
		String(input.prNumber),
		input.headSha,
		input.triggerKind,
		input.triggerSourceId,
		input.reviewerConfigHash,
	].join("|");
	return createHash("sha256").update(payload).digest("hex").slice(0, 32);
}

export interface RecordRunStartResult {
	inserted: boolean;
	priorStatus?: PrReviewRunStatus;
	coalesced?: boolean;
	activeFingerprint?: string;
}

/** Treat a `started` row older than this as crashed and eligible for retry. */
const STALE_STARTED_MS = 15 * 60 * 1000;

function projectionStatusForRunStatus(
	status: PrReviewRunStatus,
): PrReviewProjectionStatus {
	switch (status) {
		case "completed":
			return "projected";
		case "failed":
			return "failed";
		case "superseded":
			return "superseded";
		case "started":
			return "pending";
	}
}

function normalizeProjectionStatus(
	projectionStatus: string | null,
	runStatus: PrReviewRunStatus,
): PrReviewProjectionStatus {
	if (
		projectionStatus === "pending" ||
		projectionStatus === "projected" ||
		projectionStatus === "failed" ||
		projectionStatus === "superseded"
	) {
		return projectionStatus;
	}
	return projectionStatusForRunStatus(runStatus);
}

function activeClaimKey(input: {
	repoFullName: string;
	prNumber: number;
	reviewerConfigHash: string;
}): string {
	return [
		input.repoFullName,
		String(input.prNumber),
		input.reviewerConfigHash,
	].join("|");
}

async function coalesceIntoActiveRun(input: {
	activeClaimKey: string;
	headSha: string;
	triggerKind: string;
	triggerSourceId: string;
	now: string;
}): Promise<RecordRunStartResult | null> {
	const db = getDb();
	const active = await db
		.selectFrom("managed_pr_review_runs")
		.select(["fingerprint", "status", "updated_at"])
		.where("active_claim_key", "=", input.activeClaimKey)
		.executeTakeFirst();
	if (!active || active.status !== "started") return null;

	const updatedMs = Date.parse(active.updated_at);
	const ageMs = Number.isFinite(updatedMs) ? Date.now() - updatedMs : 0;
	if (ageMs >= STALE_STARTED_MS) {
		await db
			.updateTable("managed_pr_review_runs")
			.set({
				status: "superseded",
				error:
					"Superseded by a newer trigger after the active claim became stale.",
				updated_at: input.now,
				projection_status: "superseded",
				projection_updated_at: input.now,
				active_claim_key: null,
			})
			.where("fingerprint", "=", active.fingerprint)
			.execute();
		return null;
	}

	await db
		.updateTable("managed_pr_review_runs")
		.set({
			coalesced_head_sha: input.headSha,
			coalesced_trigger_kind: input.triggerKind,
			coalesced_trigger_source_id: input.triggerSourceId,
			coalesced_at: input.now,
			updated_at: input.now,
		})
		.where("fingerprint", "=", active.fingerprint)
		.execute();

	return {
		inserted: false,
		priorStatus: "started",
		coalesced: true,
		activeFingerprint: active.fingerprint,
	};
}

/**
 * Claim a run slot. Exact fingerprint idempotency is preserved, and automatic
 * PR-level bursts coalesce behind one active `(repo, PR, reviewer config)` run.
 * Returns `inserted: true` when the caller should proceed with a new session.
 *
 * The semantics are:
 * - no row and no active claim → insert and proceed.
 * - no exact row, but a fresh active claim exists → record the latest trigger
 *   on the active row and skip creating another session.
 * - row with `completed` → skip; the previous run already produced a review.
 * - row with `superseded` → skip; a later broker pass intentionally retired
 *   that run because a newer managed review was already visible.
 * - row with `failed` → reset to `started` and proceed; lets a later
 *   redelivery (or a follow-on event with the same fingerprint) recover from
 *   a transient session-create or events.send failure.
 * - row with `started` and `updated_at` older than STALE_STARTED_MS → assume
 *   the prior process crashed before it could record a result; reset and
 *   proceed.
 * - row with fresh `started` → in-flight, skip.
 */
export async function recordRunStart(
	input: PrReviewRunRecordInput,
): Promise<RecordRunStartResult> {
	await ensureRunsTable();
	const now = new Date().toISOString();
	const db = getDb();
	const claimKey = activeClaimKey(input);
	const insert = await db
		.insertInto("managed_pr_review_runs")
		.values({
			fingerprint: input.fingerprint,
			repo_full_name: input.repoFullName,
			pr_number: input.prNumber,
			head_sha: input.headSha,
			trigger_kind: input.triggerKind,
			trigger_source_id: input.triggerSourceId,
			reviewer_config_hash: input.reviewerConfigHash,
			session_id: null,
			status: "started",
			created_at: now,
			updated_at: now,
			error: null,
			projection_status: "pending",
			projection_updated_at: now,
			projection_error: null,
			github_review_id: null,
			active_claim_key: claimKey,
			coalesced_head_sha: null,
			coalesced_trigger_kind: null,
			coalesced_trigger_source_id: null,
			coalesced_at: null,
		})
		.onConflict((oc) => oc.doNothing())
		.executeTakeFirst();
	if (Number(insert?.numInsertedOrUpdatedRows ?? 0) > 0) {
		return { inserted: true };
	}

	const existing = await db
		.selectFrom("managed_pr_review_runs")
		.select(["status", "updated_at"])
		.where("fingerprint", "=", input.fingerprint)
		.executeTakeFirst();
	if (!existing) {
		const coalesced = await coalesceIntoActiveRun({
			activeClaimKey: claimKey,
			headSha: input.headSha,
			triggerKind: input.triggerKind,
			triggerSourceId: input.triggerSourceId,
			now,
		});
		if (coalesced) return coalesced;

		// Race: the conflicting active row vanished between insert attempt and
		// lookup. Try insert again without doNothing() to surface any real error.
		await db
			.insertInto("managed_pr_review_runs")
			.values({
				fingerprint: input.fingerprint,
				repo_full_name: input.repoFullName,
				pr_number: input.prNumber,
				head_sha: input.headSha,
				trigger_kind: input.triggerKind,
				trigger_source_id: input.triggerSourceId,
				reviewer_config_hash: input.reviewerConfigHash,
				session_id: null,
				status: "started",
				created_at: now,
				updated_at: now,
				error: null,
				projection_status: "pending",
				projection_updated_at: now,
				projection_error: null,
				github_review_id: null,
				active_claim_key: claimKey,
				coalesced_head_sha: null,
				coalesced_trigger_kind: null,
				coalesced_trigger_source_id: null,
				coalesced_at: null,
			})
			.execute();
		return { inserted: true };
	}

	const priorStatus = existing.status as PrReviewRunStatus;
	if (priorStatus === "completed" || priorStatus === "superseded") {
		return { inserted: false, priorStatus };
	}
	if (priorStatus === "started") {
		const updatedMs = Date.parse(existing.updated_at);
		const ageMs = Number.isFinite(updatedMs) ? Date.now() - updatedMs : 0;
		if (ageMs < STALE_STARTED_MS) {
			return { inserted: false, priorStatus };
		}
	}
	if (priorStatus === "failed") {
		const coalesced = await coalesceIntoActiveRun({
			activeClaimKey: claimKey,
			headSha: input.headSha,
			triggerKind: input.triggerKind,
			triggerSourceId: input.triggerSourceId,
			now,
		});
		if (coalesced) return coalesced;
	}

	// failed, or stale started — reset and proceed.
	await db
		.updateTable("managed_pr_review_runs")
		.set({
			status: "started",
			session_id: null,
			error: null,
			updated_at: now,
			projection_status: "pending",
			projection_updated_at: now,
			projection_error: null,
			github_review_id: null,
			active_claim_key: claimKey,
			coalesced_head_sha: null,
			coalesced_trigger_kind: null,
			coalesced_trigger_source_id: null,
			coalesced_at: null,
		})
		.where("fingerprint", "=", input.fingerprint)
		.execute();
	return { inserted: true, priorStatus };
}

export interface RecordRunResultInput {
	sessionId: string | null;
	status: PrReviewRunStatus;
	error?: string | null;
	projectionStatus?: PrReviewProjectionStatus;
	projectionError?: string | null;
	githubReviewId?: string | null;
}

export async function recordRunResult(
	fingerprint: string,
	input: RecordRunResultInput,
): Promise<void> {
	await ensureRunsTable();
	const now = new Date().toISOString();
	const projectionStatus =
		input.projectionStatus ?? projectionStatusForRunStatus(input.status);
	const updates = {
		session_id: input.sessionId,
		status: input.status,
		error: input.error ?? null,
		updated_at: now,
		projection_status: projectionStatus,
		projection_updated_at: now,
		projection_error:
			input.projectionError !== undefined
				? input.projectionError
				: projectionStatus === "failed"
					? (input.error ?? null)
					: null,
		github_review_id: input.githubReviewId ?? null,
		...(input.status === "started"
			? {}
			: {
					active_claim_key: null,
					coalesced_head_sha: null,
					coalesced_trigger_kind: null,
					coalesced_trigger_source_id: null,
					coalesced_at: null,
				}),
	};
	await getDb()
		.updateTable("managed_pr_review_runs")
		.set(updates)
		.where("fingerprint", "=", fingerprint)
		.execute();
}

export async function releaseRunActiveClaim(
	fingerprint: string,
): Promise<void> {
	await ensureRunsTable();
	await getDb()
		.updateTable("managed_pr_review_runs")
		.set({ active_claim_key: null })
		.where("fingerprint", "=", fingerprint)
		.execute();
}

export interface PrReviewRunSummary {
	fingerprint: string;
	repoFullName: string;
	prNumber: number;
	headSha: string;
	triggerKind: string;
	triggerSourceId: string;
	status: PrReviewRunStatus;
	sessionId: string | null;
	createdAt: string;
	updatedAt: string;
	error: string | null;
	projectionStatus: PrReviewProjectionStatus;
	projectionUpdatedAt: string;
	projectionError: string | null;
	githubReviewId: string | null;
	coalescedHeadSha: string | null;
	coalescedTriggerKind: string | null;
	coalescedTriggerSourceId: string | null;
	coalescedAt: string | null;
}

export interface PrReviewRunDetails extends PrReviewRunSummary {
	reviewerConfigHash: string;
}

export interface StartedPrReviewRun {
	fingerprint: string;
	repoFullName: string;
	prNumber: number;
	headSha: string;
	triggerKind: string;
	triggerSourceId: string;
	sessionId: string;
	createdAt: string;
	updatedAt: string;
	coalescedHeadSha: string | null;
	coalescedTriggerKind: string | null;
	coalescedTriggerSourceId: string | null;
	coalescedAt: string | null;
}

function mapRunDetails(row: {
	fingerprint: string;
	repo_full_name: string;
	pr_number: number;
	head_sha: string;
	trigger_kind: string;
	trigger_source_id: string;
	reviewer_config_hash: string;
	status: string;
	session_id: string | null;
	created_at: string;
	updated_at: string;
	error: string | null;
	projection_status: string | null;
	projection_updated_at: string | null;
	projection_error: string | null;
	github_review_id: string | null;
	coalesced_head_sha: string | null;
	coalesced_trigger_kind: string | null;
	coalesced_trigger_source_id: string | null;
	coalesced_at: string | null;
}): PrReviewRunDetails {
	const status = row.status as PrReviewRunStatus;
	return {
		fingerprint: row.fingerprint,
		repoFullName: row.repo_full_name,
		prNumber: row.pr_number,
		headSha: row.head_sha,
		triggerKind: row.trigger_kind,
		triggerSourceId: row.trigger_source_id,
		reviewerConfigHash: row.reviewer_config_hash,
		status,
		sessionId: row.session_id,
		createdAt: row.created_at,
		updatedAt: row.updated_at,
		error: row.error,
		projectionStatus: normalizeProjectionStatus(row.projection_status, status),
		projectionUpdatedAt: row.projection_updated_at ?? row.updated_at,
		projectionError:
			row.projection_error ?? (status === "failed" ? row.error : null),
		githubReviewId: row.github_review_id,
		coalescedHeadSha: row.coalesced_head_sha,
		coalescedTriggerKind: row.coalesced_trigger_kind,
		coalescedTriggerSourceId: row.coalesced_trigger_source_id,
		coalescedAt: row.coalesced_at,
	};
}

export async function getPrReviewRunByFingerprint(
	fingerprint: string,
): Promise<PrReviewRunDetails | null> {
	await ensureRunsTable();
	const row = await getDb()
		.selectFrom("managed_pr_review_runs")
		.selectAll()
		.where("fingerprint", "=", fingerprint)
		.executeTakeFirst();

	return row ? mapRunDetails(row) : null;
}

export async function getPrReviewRunBySessionId(
	sessionId: string,
): Promise<PrReviewRunDetails | null> {
	await ensureRunsTable();
	const row = await getDb()
		.selectFrom("managed_pr_review_runs")
		.selectAll()
		.where("session_id", "=", sessionId)
		.executeTakeFirst();

	return row ? mapRunDetails(row) : null;
}

export async function listRecentPrReviewRuns(input: {
	sinceIso: string;
	repoFullName: string;
}): Promise<PrReviewRunSummary[]> {
	await ensureRunsTable();
	const rows = await getDb()
		.selectFrom("managed_pr_review_runs")
		.select([
			"fingerprint",
			"repo_full_name",
			"pr_number",
			"head_sha",
			"trigger_kind",
			"trigger_source_id",
			"status",
			"session_id",
			"created_at",
			"updated_at",
			"error",
			"projection_status",
			"projection_updated_at",
			"projection_error",
			"github_review_id",
			"coalesced_head_sha",
			"coalesced_trigger_kind",
			"coalesced_trigger_source_id",
			"coalesced_at",
		])
		.where("created_at", ">=", input.sinceIso)
		.where("repo_full_name", "=", input.repoFullName)
		.execute();

	return rows.map((row) => {
		const status = row.status as PrReviewRunStatus;
		return {
			fingerprint: row.fingerprint,
			repoFullName: row.repo_full_name,
			prNumber: row.pr_number,
			headSha: row.head_sha,
			triggerKind: row.trigger_kind,
			triggerSourceId: row.trigger_source_id,
			status,
			sessionId: row.session_id,
			createdAt: row.created_at,
			updatedAt: row.updated_at,
			error: row.error,
			projectionStatus: normalizeProjectionStatus(
				row.projection_status,
				status,
			),
			projectionUpdatedAt: row.projection_updated_at ?? row.updated_at,
			projectionError:
				row.projection_error ?? (status === "failed" ? row.error : null),
			githubReviewId: row.github_review_id,
			coalescedHeadSha: row.coalesced_head_sha,
			coalescedTriggerKind: row.coalesced_trigger_kind,
			coalescedTriggerSourceId: row.coalesced_trigger_source_id,
			coalescedAt: row.coalesced_at,
		};
	});
}

export type PrReviewRunOperatorState =
	| "starting"
	| "stuck_starting"
	| "executing"
	| "needs_projection"
	| "failed"
	| "terminal";

export interface PrReviewRunStateThresholds {
	startingTimeoutMinutes: number;
	projectionTimeoutMinutes: number;
}

export interface ClassifiedPrReviewRun extends PrReviewRunSummary {
	state: PrReviewRunOperatorState;
	ageMinutes: number;
}

export interface PrReviewRunStateBuckets {
	starting: ClassifiedPrReviewRun[];
	stuckStarting: ClassifiedPrReviewRun[];
	executing: ClassifiedPrReviewRun[];
	needsProjection: ClassifiedPrReviewRun[];
	failed: ClassifiedPrReviewRun[];
	terminal: ClassifiedPrReviewRun[];
}

function elapsedMinutes(sinceIso: string, now: Date): number {
	const sinceMs = Date.parse(sinceIso);
	const nowMs = now.getTime();
	if (!Number.isFinite(sinceMs) || !Number.isFinite(nowMs)) return 0;
	return Math.max(0, Math.floor((nowMs - sinceMs) / (60 * 1000)));
}

export function classifyPrReviewRun(
	run: PrReviewRunSummary,
	options: {
		now?: Date;
		thresholds: PrReviewRunStateThresholds;
	},
): ClassifiedPrReviewRun {
	const now = options.now ?? new Date();
	let ageSource = run.updatedAt;
	let state: PrReviewRunOperatorState;

	if (run.status === "failed" || run.projectionStatus === "failed") {
		state = "failed";
	} else if (
		run.status === "completed" ||
		run.status === "superseded" ||
		run.projectionStatus === "projected" ||
		run.projectionStatus === "superseded"
	) {
		state = "terminal";
	} else if (!run.sessionId) {
		const ageMinutes = elapsedMinutes(ageSource, now);
		state =
			ageMinutes >= options.thresholds.startingTimeoutMinutes
				? "stuck_starting"
				: "starting";
	} else {
		// Once a session exists, age reports projection staleness rather than
		// wall-clock run age so operators can see when the broker is overdue.
		ageSource = run.projectionUpdatedAt;
		const ageMinutes = elapsedMinutes(ageSource, now);
		state =
			ageMinutes >= options.thresholds.projectionTimeoutMinutes
				? "needs_projection"
				: "executing";
	}

	return { ...run, state, ageMinutes: elapsedMinutes(ageSource, now) };
}

export function bucketPrReviewRuns(
	runs: PrReviewRunSummary[],
	options: {
		now?: Date;
		thresholds: PrReviewRunStateThresholds;
	},
): PrReviewRunStateBuckets {
	const buckets: PrReviewRunStateBuckets = {
		starting: [],
		stuckStarting: [],
		executing: [],
		needsProjection: [],
		failed: [],
		terminal: [],
	};

	for (const run of runs) {
		const classified = classifyPrReviewRun(run, options);
		switch (classified.state) {
			case "starting":
				buckets.starting.push(classified);
				break;
			case "stuck_starting":
				buckets.stuckStarting.push(classified);
				break;
			case "executing":
				buckets.executing.push(classified);
				break;
			case "needs_projection":
				buckets.needsProjection.push(classified);
				break;
			case "failed":
				buckets.failed.push(classified);
				break;
			case "terminal":
				buckets.terminal.push(classified);
				break;
		}
	}

	return buckets;
}

export async function listStartedPrReviewRuns(
	input: {
		limit?: number;
		repoFullName?: string;
	} = {},
): Promise<StartedPrReviewRun[]> {
	await ensureRunsTable();
	let query = getDb()
		.selectFrom("managed_pr_review_runs")
		.select([
			"fingerprint",
			"repo_full_name",
			"pr_number",
			"head_sha",
			"trigger_kind",
			"trigger_source_id",
			"session_id",
			"created_at",
			"updated_at",
			"coalesced_head_sha",
			"coalesced_trigger_kind",
			"coalesced_trigger_source_id",
			"coalesced_at",
		])
		.where("status", "=", "started")
		.where("session_id", "is not", null)
		.orderBy("updated_at", "asc")
		.limit(input.limit ?? 10);
	if (input.repoFullName) {
		query = query.where("repo_full_name", "=", input.repoFullName);
	}
	const rows = await query.execute();

	return rows
		.filter((row) => row.session_id)
		.map((row) => ({
			fingerprint: row.fingerprint,
			repoFullName: row.repo_full_name,
			prNumber: row.pr_number,
			headSha: row.head_sha,
			triggerKind: row.trigger_kind,
			triggerSourceId: row.trigger_source_id,
			sessionId: row.session_id as string,
			createdAt: row.created_at,
			updatedAt: row.updated_at,
			coalescedHeadSha: row.coalesced_head_sha,
			coalescedTriggerKind: row.coalesced_trigger_kind,
			coalescedTriggerSourceId: row.coalesced_trigger_source_id,
			coalescedAt: row.coalesced_at,
		}));
}

/** Test-only hook so per-test in-memory DBs re-run table creation. */
export function __resetPrReviewRunsForTests(): void {
	migrated = false;
}
