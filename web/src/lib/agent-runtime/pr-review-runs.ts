import { createHash } from "node:crypto";
import { getDb } from "../db";

export type PrReviewRunStatus = "started" | "completed" | "failed";

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
		.execute();
	await db.schema
		.createIndex("idx_managed_pr_review_runs_pr")
		.ifNotExists()
		.on("managed_pr_review_runs")
		.columns(["repo_full_name", "pr_number"])
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
}

/** Treat a `started` row older than this as crashed and eligible for retry. */
const STALE_STARTED_MS = 15 * 60 * 1000;

/**
 * Claim a run slot for the fingerprint. Returns `inserted: true` when the
 * caller should proceed with the session; `inserted: false` when this run
 * should be treated as an idempotent skip.
 *
 * The semantics are:
 * - no row → insert and proceed.
 * - row with `completed` → skip; the previous run already produced a review.
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
		})
		.onConflict((oc) => oc.column("fingerprint").doNothing())
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
		// Race: row vanished between insert attempt and select. Try insert again
		// without doNothing() to surface any real error to the caller.
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
			})
			.execute();
		return { inserted: true };
	}

	const priorStatus = existing.status as PrReviewRunStatus;
	if (priorStatus === "completed") {
		return { inserted: false, priorStatus };
	}
	if (priorStatus === "started") {
		const updatedMs = Date.parse(existing.updated_at);
		const ageMs = Number.isFinite(updatedMs) ? Date.now() - updatedMs : 0;
		if (ageMs < STALE_STARTED_MS) {
			return { inserted: false, priorStatus };
		}
	}

	// failed, or stale started — reset and proceed.
	await db
		.updateTable("managed_pr_review_runs")
		.set({
			status: "started",
			session_id: null,
			error: null,
			updated_at: now,
		})
		.where("fingerprint", "=", input.fingerprint)
		.execute();
	return { inserted: true, priorStatus };
}

export interface RecordRunResultInput {
	sessionId: string | null;
	status: PrReviewRunStatus;
	error?: string | null;
}

export async function recordRunResult(
	fingerprint: string,
	input: RecordRunResultInput,
): Promise<void> {
	await ensureRunsTable();
	await getDb()
		.updateTable("managed_pr_review_runs")
		.set({
			session_id: input.sessionId,
			status: input.status,
			error: input.error ?? null,
			updated_at: new Date().toISOString(),
		})
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
		])
		.where("created_at", ">=", input.sinceIso)
		.where("repo_full_name", "=", input.repoFullName)
		.execute();

	return rows.map((row) => ({
		fingerprint: row.fingerprint,
		repoFullName: row.repo_full_name,
		prNumber: row.pr_number,
		headSha: row.head_sha,
		triggerKind: row.trigger_kind,
		triggerSourceId: row.trigger_source_id,
		status: row.status as PrReviewRunStatus,
		sessionId: row.session_id,
		createdAt: row.created_at,
		updatedAt: row.updated_at,
	}));
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
		}));
}

/** Test-only hook so per-test in-memory DBs re-run table creation. */
export function __resetPrReviewRunsForTests(): void {
	migrated = false;
}
