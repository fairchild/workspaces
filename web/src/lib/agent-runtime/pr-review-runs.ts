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
}

/**
 * Insert a "started" run row keyed on fingerprint. Returns
 * { inserted: false } when a row with the same fingerprint already exists,
 * which the caller treats as an idempotent skip.
 */
export async function recordRunStart(
	input: PrReviewRunRecordInput,
): Promise<RecordRunStartResult> {
	await ensureRunsTable();
	const now = new Date().toISOString();
	const result = await getDb()
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
	const inserted = Number(result?.numInsertedOrUpdatedRows ?? 0) > 0;
	return { inserted };
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

/** Test-only hook so per-test in-memory DBs re-run table creation. */
export function __resetPrReviewRunsForTests(): void {
	migrated = false;
}
