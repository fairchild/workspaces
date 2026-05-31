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

export type PrReviewProjectionType = "github_status" | "github_review";

export type PrReviewProjectionLedgerState =
	| "pending"
	| "projecting"
	| "projected"
	| "failed"
	| "superseded";

export type PrReviewProjectionErrorKind =
	| "auth"
	| "rate_limit"
	| "transient_api"
	| "validation"
	| "unknown";

export type PrReviewFailureKind =
	| "session_start_failed"
	| "session_output_failed"
	| "review_intent_invalid"
	| "pr_metadata_unavailable"
	| "github_projection_failed"
	| "broker_failed"
	| "stale_active_claim"
	| "unknown";

export type PrReviewExecutionState =
	| "waiting_for_session"
	| "running_session"
	| "completed"
	| "failed"
	| "superseded";

export interface PrReviewRunReviewIntent {
	event: string;
	body: string;
	labels: string[];
}

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
let projectionsMigrated = false;

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
		.addColumn("failure_kind", "text")
		.addColumn("failure_message", "text")
		.addColumn("failure_retryable", "integer")
		.addColumn("failed_at", "text")
		.addColumn("projection_status", "text")
		.addColumn("projection_updated_at", "text")
		.addColumn("projection_error", "text")
		.addColumn("github_review_id", "text")
		.addColumn("review_intent_event", "text")
		.addColumn("review_intent_body", "text")
		.addColumn("review_intent_labels", "text")
		.addColumn("review_intent_recorded_at", "text")
		.addColumn("active_claim_key", "text")
		.addColumn("coalesced_head_sha", "text")
		.addColumn("coalesced_trigger_kind", "text")
		.addColumn("coalesced_trigger_source_id", "text")
		.addColumn("coalesced_at", "text")
		.execute();
	for (const [column, type] of [
		["failure_kind", "text"],
		["failure_message", "text"],
		["failure_retryable", "integer"],
		["failed_at", "text"],
		["projection_status", "text"],
		["projection_updated_at", "text"],
		["projection_error", "text"],
		["github_review_id", "text"],
		["review_intent_event", "text"],
		["review_intent_body", "text"],
		["review_intent_labels", "text"],
		["review_intent_recorded_at", "text"],
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

async function ensureProjectionLedgerTable(): Promise<void> {
	await ensureRunsTable();
	if (projectionsMigrated) return;
	const db = getDb();
	await db.schema
		.createTable("managed_pr_review_projections")
		.ifNotExists()
		.addColumn("projection_id", "text", (c) => c.primaryKey())
		.addColumn("run_fingerprint", "text", (c) => c.notNull())
		.addColumn("projection_type", "text", (c) => c.notNull())
		.addColumn("projection_key", "text", (c) => c.notNull())
		.addColumn("desired_payload_hash", "text", (c) => c.notNull())
		.addColumn("desired_payload", "text", (c) => c.notNull())
		.addColumn("state", "text", (c) => c.notNull())
		.addColumn("attempts", "integer", (c) => c.notNull().defaultTo(0))
		.addColumn("last_attempted_at", "text")
		.addColumn("observed_external_id", "text")
		.addColumn("error_kind", "text")
		.addColumn("error_text", "text")
		.addColumn("created_at", "text", (c) => c.notNull())
		.addColumn("updated_at", "text", (c) => c.notNull())
		.execute();
	await db.schema
		.createIndex("ux_managed_pr_review_projections_desired")
		.ifNotExists()
		.on("managed_pr_review_projections")
		.columns([
			"run_fingerprint",
			"projection_type",
			"projection_key",
			"desired_payload_hash",
		])
		.unique()
		.execute();
	await db.schema
		.createIndex("idx_managed_pr_review_projections_run")
		.ifNotExists()
		.on("managed_pr_review_projections")
		.column("run_fingerprint")
		.execute();
	await db.schema
		.createIndex("idx_managed_pr_review_projections_state")
		.ifNotExists()
		.on("managed_pr_review_projections")
		.columns(["state", "updated_at"])
		.execute();
	projectionsMigrated = true;
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

function computeProjectionId(input: {
	runFingerprint: string;
	type: PrReviewProjectionType;
	projectionKey: string;
	desiredPayloadHash: string;
}): string {
	return createHash("sha256")
		.update(
			[
				input.runFingerprint,
				input.type,
				input.projectionKey,
				input.desiredPayloadHash,
			].join("|"),
		)
		.digest("hex")
		.slice(0, 32);
}

function normalizeProjectionPayload(
	value: unknown,
	options: { stringLimit: number | null },
	depth = 0,
): unknown {
	if (value === null || typeof value === "boolean") return value;
	if (typeof value === "number") return Number.isFinite(value) ? value : null;
	if (typeof value === "string") {
		const redacted = redactSensitiveText(value);
		return options.stringLimit === null
			? redacted
			: truncateText(redacted, options.stringLimit);
	}
	if (Array.isArray(value)) {
		if (depth >= MAX_PROJECTION_DEPTH) return "[truncated-depth]";
		const items = value
			.slice(0, MAX_PROJECTION_ARRAY_ITEMS)
			.map((item) => normalizeProjectionPayload(item, options, depth + 1));
		if (value.length > MAX_PROJECTION_ARRAY_ITEMS) {
			items.push(
				`[truncated ${value.length - MAX_PROJECTION_ARRAY_ITEMS} items]`,
			);
		}
		return items;
	}
	if (typeof value === "object") {
		if (depth >= MAX_PROJECTION_DEPTH) return "[truncated-depth]";
		const input = value as Record<string, unknown>;
		const output: Record<string, unknown> = {};
		const keys = Object.keys(input).sort();
		for (const key of keys.slice(0, MAX_PROJECTION_OBJECT_KEYS)) {
			const item = input[key];
			if (item === undefined || typeof item === "function") continue;
			output[key] = SENSITIVE_PROJECTION_KEY.test(key)
				? "[redacted]"
				: normalizeProjectionPayload(item, options, depth + 1);
		}
		if (keys.length > MAX_PROJECTION_OBJECT_KEYS) {
			output.__truncatedKeys = keys.length - MAX_PROJECTION_OBJECT_KEYS;
		}
		return output;
	}
	return String(value);
}

function stableProjectionJson(
	value: unknown,
	options: { stringLimit: number | null },
): string {
	return JSON.stringify(normalizeProjectionPayload(value, options));
}

function boundProjectionPayloadJson(canonicalJson: string): string {
	if (canonicalJson.length <= MAX_PROJECTION_PAYLOAD_JSON_LENGTH) {
		return canonicalJson;
	}
	let preview = canonicalJson.slice(0, MAX_PROJECTION_PAYLOAD_JSON_LENGTH);
	let bounded = "";
	while (preview.length > 0) {
		bounded = JSON.stringify({
			truncated: true,
			originalLength: canonicalJson.length,
			preview,
		});
		if (bounded.length <= MAX_PROJECTION_PAYLOAD_JSON_LENGTH) return bounded;
		preview = preview.slice(0, -128);
	}
	return JSON.stringify({
		truncated: true,
		originalLength: canonicalJson.length,
		preview: "",
	});
}

function sanitizeProjectionError(
	message: string | null | undefined,
): string | null {
	if (!message) return null;
	return truncateText(
		redactSensitiveText(message).replace(/\s+$/g, ""),
		MAX_PROJECTION_ERROR_LENGTH,
	);
}

export function classifyPrReviewProjectionError(input: {
	status?: number | null;
	message?: string | null;
}): PrReviewProjectionErrorKind {
	const status = input.status ?? null;
	const lower = String(input.message ?? "").toLowerCase();
	if (status === 401 || status === 403) return "auth";
	if (
		lower.includes("bad credentials") ||
		lower.includes("unauthorized") ||
		lower.includes("forbidden") ||
		lower.includes("permission") ||
		lower.includes("token")
	) {
		return "auth";
	}
	if (
		status === 429 ||
		lower.includes("rate limit") ||
		lower.includes("secondary rate")
	) {
		return "rate_limit";
	}
	if (
		status === 400 ||
		status === 422 ||
		lower.includes("validation") ||
		lower.includes("invalid")
	) {
		return "validation";
	}
	if (
		(status !== null && status >= 500) ||
		lower.includes("timeout") ||
		lower.includes("temporar") ||
		lower.includes("econnreset") ||
		lower.includes("fetch failed")
	) {
		return "transient_api";
	}
	return "unknown";
}

function prepareProjectionPayload(desiredPayload: unknown): {
	desiredPayloadHash: string;
	boundedPayloadJson: string;
} {
	const hashJson = stableProjectionJson(desiredPayload, { stringLimit: null });
	const storageJson = stableProjectionJson(desiredPayload, {
		stringLimit: MAX_PROJECTION_STRING_LENGTH,
	});
	return {
		desiredPayloadHash: createHash("sha256").update(hashJson).digest("hex"),
		boundedPayloadJson: boundProjectionPayloadJson(storageJson),
	};
}

function normalizeProjectionLedgerState(
	state: string,
): PrReviewProjectionLedgerState {
	if (
		state === "pending" ||
		state === "projecting" ||
		state === "projected" ||
		state === "failed" ||
		state === "superseded"
	) {
		return state;
	}
	return "pending";
}

function normalizeProjectionType(type: string): PrReviewProjectionType {
	return type === "github_review" ? "github_review" : "github_status";
}

function normalizeProjectionErrorKind(
	kind: string | null,
): PrReviewProjectionErrorKind | null {
	if (
		kind === "auth" ||
		kind === "rate_limit" ||
		kind === "transient_api" ||
		kind === "validation" ||
		kind === "unknown"
	) {
		return kind;
	}
	return null;
}

export interface RecordRunStartResult {
	inserted: boolean;
	priorStatus?: PrReviewRunStatus;
	coalesced?: boolean;
	activeFingerprint?: string;
}

/** Treat a `started` row older than this as crashed and eligible for retry. */
const STALE_STARTED_MS = 15 * 60 * 1000;
const MAX_FAILURE_MESSAGE_LENGTH = 600;
const MAX_PROJECTION_ERROR_LENGTH = 600;
const MAX_PROJECTION_STRING_LENGTH = 1000;
const MAX_PROJECTION_PAYLOAD_JSON_LENGTH = 4096;
const MAX_PROJECTION_ARRAY_ITEMS = 50;
const MAX_PROJECTION_OBJECT_KEYS = 50;
const MAX_PROJECTION_DEPTH = 6;

const TOKEN_REDACTIONS: RegExp[] = [
	/ghp_[A-Za-z0-9_]{20,}/g,
	/github_pat_[A-Za-z0-9_]{20,}/g,
	/(?:sk|sk-ant|sk-proj)-[A-Za-z0-9_-]{20,}/g,
	/\bBearer\s+[A-Za-z0-9._-]{20,}/gi,
	/\btoken["'\s:=]+[A-Za-z0-9._-]{20,}/gi,
	/\bsecret["'\s:=]+[A-Za-z0-9._-]{20,}/gi,
];

const SENSITIVE_PROJECTION_KEY =
	/(authorization|token|secret|password|private[_-]?key|raw[_-]?webhook|webhook[_-]?payload)/i;

function redactSensitiveText(message: string): string {
	let sanitized = message;
	for (const pattern of TOKEN_REDACTIONS) {
		sanitized = sanitized.replace(pattern, "[redacted]");
	}
	return sanitized;
}

function truncateText(value: string, limit: number): string {
	if (value.length <= limit) return value;
	return `${value.slice(0, limit - 1)}...`;
}

function sanitizeFailureMessage(
	message: string | null | undefined,
): string | null {
	if (!message) return null;
	let sanitized = redactSensitiveText(message);
	sanitized = sanitized.replace(/\s+$/g, "");
	if (sanitized.length <= MAX_FAILURE_MESSAGE_LENGTH) return sanitized;
	return `${sanitized.slice(0, MAX_FAILURE_MESSAGE_LENGTH - 1)}...`;
}

function serializeReviewIntentLabels(labels: string[]): string {
	return JSON.stringify(
		labels.map((label) => label.trim()).filter((label) => label.length > 0),
	);
}

function parseReviewIntentLabels(labelsJson: string | null): string[] {
	if (!labelsJson) return [];
	try {
		const parsed = JSON.parse(labelsJson);
		if (!Array.isArray(parsed)) return [];
		return parsed
			.map((label) => String(label).trim())
			.filter((label) => label.length > 0);
	} catch {
		return [];
	}
}

function reviewIntentFromRow(row: {
	review_intent_event: string | null;
	review_intent_body: string | null;
	review_intent_labels: string | null;
}): PrReviewRunReviewIntent | null {
	const event = row.review_intent_event?.trim() ?? "";
	const body = row.review_intent_body?.trim() ?? "";
	if (!event || !body) return null;
	return {
		event,
		body,
		labels: parseReviewIntentLabels(row.review_intent_labels),
	};
}

function classifyFailureKind(
	status: PrReviewRunStatus,
	message: string | null | undefined,
): PrReviewFailureKind | null {
	if (status !== "failed") return null;
	const lower = String(message ?? "").toLowerCase();
	if (
		lower.includes("review intent") ||
		lower.includes("invalid intent") ||
		lower.includes("json")
	) {
		return "review_intent_invalid";
	}
	if (
		lower.includes("could not resolve pr metadata") ||
		lower.includes("could not resolve head metadata")
	) {
		return "pr_metadata_unavailable";
	}
	if (
		lower.includes("github") ||
		lower.includes("status") ||
		/\b(?:401|403|404|422|500|502|503)\b/.test(lower)
	) {
		return "github_projection_failed";
	}
	if (lower.includes("session") || lower.includes("managed agent")) {
		return "session_output_failed";
	}
	return "broker_failed";
}

function defaultRetryable(kind: PrReviewFailureKind | null): boolean | null {
	switch (kind) {
		case null:
			return null;
		case "review_intent_invalid":
			return false;
		case "github_projection_failed":
		case "pr_metadata_unavailable":
		case "session_output_failed":
		case "session_start_failed":
		case "broker_failed":
		case "stale_active_claim":
		case "unknown":
			return true;
	}
}

function normalizeFailureRetryable(value: boolean | null): number | null {
	if (value === null) return null;
	return value ? 1 : 0;
}

function normalizeFailureKind(kind: string | null): PrReviewFailureKind | null {
	if (
		kind === "session_start_failed" ||
		kind === "session_output_failed" ||
		kind === "review_intent_invalid" ||
		kind === "pr_metadata_unavailable" ||
		kind === "github_projection_failed" ||
		kind === "broker_failed" ||
		kind === "stale_active_claim" ||
		kind === "unknown"
	) {
		return kind;
	}
	return null;
}

function executionStateForRun(input: {
	status: PrReviewRunStatus;
	sessionId: string | null;
}): PrReviewExecutionState {
	if (input.status === "completed") return "completed";
	if (input.status === "failed") return "failed";
	if (input.status === "superseded") return "superseded";
	return input.sessionId ? "running_session" : "waiting_for_session";
}

function nextActionForRun(input: {
	status: PrReviewRunStatus;
	sessionId: string | null;
	projectionStatus: PrReviewProjectionStatus;
	failureRetryable: boolean | null;
	coalescedAt: string | null;
}): string {
	if (input.coalescedAt && input.status === "started") {
		return "Broker will supersede this run and start one follow-up review for the latest PR state.";
	}
	if (input.status === "started" && !input.sessionId) {
		return "Waiting for the managed-agent session to be created.";
	}
	if (input.status === "started") {
		return "Waiting for the broker to collect completed managed-agent output.";
	}
	if (input.status === "completed" && input.projectionStatus === "projected") {
		return "No action needed; the ReviewRun has been published to GitHub.";
	}
	if (input.status === "completed") {
		return "Broker or repair tooling should publish the completed ReviewRun projection to GitHub.";
	}
	if (input.status === "superseded") {
		return "No action needed for this run; a newer run or review replaced it.";
	}
	if (input.failureRetryable) {
		return "Retry is allowed after confirming this run still targets the current PR head.";
	}
	return "Manual inspection required before retry.";
}

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
				failure_kind: "stale_active_claim",
				failure_message:
					"Superseded by a newer trigger after the active claim became stale.",
				failure_retryable: 1,
				failed_at: input.now,
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
			failure_kind: null,
			failure_message: null,
			failure_retryable: null,
			failed_at: null,
			projection_status: "pending",
			projection_updated_at: now,
			projection_error: null,
			github_review_id: null,
			review_intent_event: null,
			review_intent_body: null,
			review_intent_labels: null,
			review_intent_recorded_at: null,
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
				failure_kind: null,
				failure_message: null,
				failure_retryable: null,
				failed_at: null,
				projection_status: "pending",
				projection_updated_at: now,
				projection_error: null,
				github_review_id: null,
				review_intent_event: null,
				review_intent_body: null,
				review_intent_labels: null,
				review_intent_recorded_at: null,
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
			failure_kind: null,
			failure_message: null,
			failure_retryable: null,
			failed_at: null,
			updated_at: now,
			projection_status: "pending",
			projection_updated_at: now,
			projection_error: null,
			github_review_id: null,
			review_intent_event: null,
			review_intent_body: null,
			review_intent_labels: null,
			review_intent_recorded_at: null,
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

export interface PrReviewProjectionRecord {
	projectionId: string;
	runFingerprint: string;
	type: PrReviewProjectionType;
	projectionKey: string;
	desiredPayloadHash: string;
	desiredPayload: unknown;
	state: PrReviewProjectionLedgerState;
	attempts: number;
	lastAttemptedAt: string | null;
	observedExternalId: string | null;
	errorKind: PrReviewProjectionErrorKind | null;
	errorText: string | null;
	createdAt: string;
	updatedAt: string;
}

export interface BeginPrReviewProjectionAttemptInput {
	runFingerprint: string;
	type: PrReviewProjectionType;
	projectionKey: string;
	desiredPayload: unknown;
}

export interface BeginPrReviewProjectionAttemptResult {
	projectionId: string;
	desiredPayloadHash: string;
	shouldProject: boolean;
	attempts: number;
	state: PrReviewProjectionLedgerState;
	observedExternalId: string | null;
}

function parseStoredProjectionPayload(payload: string): unknown {
	try {
		return JSON.parse(payload);
	} catch {
		return { unparseable: true };
	}
}

function mapProjectionRecord(row: {
	projection_id: string;
	run_fingerprint: string;
	projection_type: string;
	projection_key: string;
	desired_payload_hash: string;
	desired_payload: string;
	state: string;
	attempts: number;
	last_attempted_at: string | null;
	observed_external_id: string | null;
	error_kind: string | null;
	error_text: string | null;
	created_at: string;
	updated_at: string;
}): PrReviewProjectionRecord {
	return {
		projectionId: row.projection_id,
		runFingerprint: row.run_fingerprint,
		type: normalizeProjectionType(row.projection_type),
		projectionKey: row.projection_key,
		desiredPayloadHash: row.desired_payload_hash,
		desiredPayload: parseStoredProjectionPayload(row.desired_payload),
		state: normalizeProjectionLedgerState(row.state),
		attempts: Number(row.attempts ?? 0),
		lastAttemptedAt: row.last_attempted_at,
		observedExternalId: row.observed_external_id,
		errorKind: normalizeProjectionErrorKind(row.error_kind),
		errorText: sanitizeProjectionError(row.error_text),
		createdAt: row.created_at,
		updatedAt: row.updated_at,
	};
}

export async function beginPrReviewProjectionAttempt(
	input: BeginPrReviewProjectionAttemptInput,
): Promise<BeginPrReviewProjectionAttemptResult> {
	await ensureProjectionLedgerTable();
	const now = new Date().toISOString();
	const { desiredPayloadHash, boundedPayloadJson } = prepareProjectionPayload(
		input.desiredPayload,
	);
	const projectionId = computeProjectionId({
		runFingerprint: input.runFingerprint,
		type: input.type,
		projectionKey: input.projectionKey,
		desiredPayloadHash,
	});
	const db = getDb();
	await db
		.insertInto("managed_pr_review_projections")
		.values({
			projection_id: projectionId,
			run_fingerprint: input.runFingerprint,
			projection_type: input.type,
			projection_key: input.projectionKey,
			desired_payload_hash: desiredPayloadHash,
			desired_payload: boundedPayloadJson,
			state: "pending",
			attempts: 0,
			last_attempted_at: null,
			observed_external_id: null,
			error_kind: null,
			error_text: null,
			created_at: now,
			updated_at: now,
		})
		.onConflict((oc) => oc.doNothing())
		.executeTakeFirst();

	const existing = await db
		.selectFrom("managed_pr_review_projections")
		.select([
			"state",
			"attempts",
			"observed_external_id",
			"desired_payload_hash",
		])
		.where("projection_id", "=", projectionId)
		.executeTakeFirstOrThrow();
	const existingState = normalizeProjectionLedgerState(existing.state);
	if (existingState === "projected") {
		return {
			projectionId,
			desiredPayloadHash: existing.desired_payload_hash,
			shouldProject: false,
			attempts: Number(existing.attempts ?? 0),
			state: existingState,
			observedExternalId: existing.observed_external_id,
		};
	}

	const attempts = Number(existing.attempts ?? 0) + 1;
	await db
		.updateTable("managed_pr_review_projections")
		.set({
			state: "projecting",
			attempts,
			last_attempted_at: now,
			error_kind: null,
			error_text: null,
			updated_at: now,
		})
		.where("projection_id", "=", projectionId)
		.execute();
	return {
		projectionId,
		desiredPayloadHash,
		shouldProject: true,
		attempts,
		state: "projecting",
		observedExternalId: existing.observed_external_id,
	};
}

export async function recordPrReviewProjectionSuccess(
	projectionId: string,
	input: { observedExternalId?: string | null } = {},
): Promise<void> {
	await ensureProjectionLedgerTable();
	const now = new Date().toISOString();
	const updates = {
		state: "projected" as const,
		error_kind: null,
		error_text: null,
		updated_at: now,
		// Omitted means "no new GitHub ID", not "erase the known GitHub ID".
		...(input.observedExternalId !== undefined
			? { observed_external_id: input.observedExternalId }
			: {}),
	};
	await getDb()
		.updateTable("managed_pr_review_projections")
		.set(updates)
		.where("projection_id", "=", projectionId)
		.execute();
}

export async function recordPrReviewProjectionFailure(
	projectionId: string,
	input: {
		errorKind: PrReviewProjectionErrorKind;
		errorText: string;
	},
): Promise<void> {
	await ensureProjectionLedgerTable();
	const now = new Date().toISOString();
	await getDb()
		.updateTable("managed_pr_review_projections")
		.set({
			state: "failed",
			error_kind: input.errorKind,
			error_text: sanitizeProjectionError(input.errorText),
			updated_at: now,
		})
		.where("projection_id", "=", projectionId)
		.execute();
}

export async function listPrReviewProjectionsForRun(
	runFingerprint: string,
): Promise<PrReviewProjectionRecord[]> {
	await ensureProjectionLedgerTable();
	const rows = await getDb()
		.selectFrom("managed_pr_review_projections")
		.selectAll()
		.where("run_fingerprint", "=", runFingerprint)
		.orderBy("created_at", "asc")
		.orderBy("projection_type", "asc")
		.execute();
	return rows.map(mapProjectionRecord);
}

export interface RecordRunResultInput {
	sessionId: string | null;
	status: PrReviewRunStatus;
	error?: string | null;
	failureKind?: PrReviewFailureKind | null;
	failureRetryable?: boolean | null;
	projectionStatus?: PrReviewProjectionStatus;
	projectionError?: string | null;
	githubReviewId?: string | null;
	reviewIntent?: PrReviewRunReviewIntent | null;
}

const TERMINAL_RUN_STATUSES = new Set<PrReviewRunStatus>([
	"completed",
	"failed",
	"superseded",
]);

async function assertTransitionAllowed(
	fingerprint: string,
	nextStatus: PrReviewRunStatus,
): Promise<void> {
	const current = await getDb()
		.selectFrom("managed_pr_review_runs")
		.select(["status", "projection_status"])
		.where("fingerprint", "=", fingerprint)
		.executeTakeFirst();
	if (!current) {
		throw new Error(`ReviewRun ${fingerprint} does not exist`);
	}
	const currentStatus = current.status as PrReviewRunStatus;
	const currentProjectionStatus = normalizeProjectionStatus(
		current.projection_status,
		currentStatus,
	);
	if (
		currentStatus === "completed" &&
		nextStatus === "superseded" &&
		currentProjectionStatus !== "projected"
	) {
		return;
	}
	if (
		TERMINAL_RUN_STATUSES.has(currentStatus) &&
		currentStatus !== nextStatus
	) {
		throw new Error(
			`ReviewRun ${fingerprint} is terminal (${currentStatus}); cannot mark ${nextStatus}`,
		);
	}
}

interface RunLifecycleUpdateInput {
	sessionId: string | null;
	status: PrReviewRunStatus;
	error?: string | null;
	failureKind?: PrReviewFailureKind | null;
	failureRetryable?: boolean | null;
	projectionStatus?: PrReviewProjectionStatus;
	projectionError?: string | null;
	githubReviewId?: string | null;
	reviewIntent?: PrReviewRunReviewIntent | null;
}

async function updateRunLifecycle(
	fingerprint: string,
	input: RunLifecycleUpdateInput,
): Promise<void> {
	await ensureRunsTable();
	const now = new Date().toISOString();
	await assertTransitionAllowed(fingerprint, input.status);
	const projectionStatus =
		input.projectionStatus ?? projectionStatusForRunStatus(input.status);
	const failureKind =
		input.failureKind ?? classifyFailureKind(input.status, input.error);
	const sanitizedError = sanitizeFailureMessage(input.error);
	const failureMessage =
		input.status === "failed" || failureKind ? sanitizedError : null;
	const failureRetryable =
		input.failureRetryable ?? defaultRetryable(failureKind);
	const projectionError =
		input.projectionError !== undefined
			? sanitizeFailureMessage(input.projectionError)
			: projectionStatus === "failed"
				? failureMessage
				: null;
	const reviewIntentUpdates =
		input.reviewIntent !== undefined
			? {
					review_intent_event: input.reviewIntent?.event ?? null,
					review_intent_body: input.reviewIntent?.body ?? null,
					review_intent_labels: input.reviewIntent
						? serializeReviewIntentLabels(input.reviewIntent.labels)
						: null,
					review_intent_recorded_at: input.reviewIntent ? now : null,
				}
			: {};
	const updates = {
		session_id: input.sessionId,
		status: input.status,
		error: sanitizedError,
		failure_kind: failureKind,
		failure_message: failureMessage,
		failure_retryable: normalizeFailureRetryable(failureRetryable),
		failed_at: failureKind ? now : null,
		updated_at: now,
		projection_status: projectionStatus,
		projection_updated_at: now,
		projection_error: projectionError,
		github_review_id: input.githubReviewId ?? null,
		...reviewIntentUpdates,
		...(input.status === "started"
			? {
					review_intent_event: null,
					review_intent_body: null,
					review_intent_labels: null,
					review_intent_recorded_at: null,
				}
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

export async function markRunSessionStarted(
	fingerprint: string,
	input: { sessionId: string },
): Promise<void> {
	await updateRunLifecycle(fingerprint, {
		sessionId: input.sessionId,
		status: "started",
		projectionStatus: "pending",
	});
}

export async function markRunCompleted(
	fingerprint: string,
	input: {
		sessionId: string | null;
		githubReviewId?: string | null;
		projectionStatus?: PrReviewProjectionStatus;
		projectionError?: string | null;
		reviewIntent?: PrReviewRunReviewIntent | null;
	},
): Promise<void> {
	await updateRunLifecycle(fingerprint, {
		sessionId: input.sessionId,
		status: "completed",
		githubReviewId: input.githubReviewId ?? null,
		projectionStatus: input.projectionStatus,
		projectionError: input.projectionError,
		reviewIntent: input.reviewIntent,
	});
}

export async function markRunFailed(
	fingerprint: string,
	input: {
		sessionId: string | null;
		error: string;
		failureKind?: PrReviewFailureKind | null;
		failureRetryable?: boolean | null;
		projectionError?: string | null;
	},
): Promise<void> {
	await updateRunLifecycle(fingerprint, {
		sessionId: input.sessionId,
		status: "failed",
		error: input.error,
		failureKind: input.failureKind,
		failureRetryable: input.failureRetryable,
		projectionStatus: "failed",
		projectionError: input.projectionError,
	});
}

export async function markRunSuperseded(
	fingerprint: string,
	input: {
		sessionId: string | null;
		reason: string;
		projectionStatus?: PrReviewProjectionStatus;
		githubReviewId?: string | null;
	},
): Promise<void> {
	await updateRunLifecycle(fingerprint, {
		sessionId: input.sessionId,
		status: "superseded",
		error: input.reason,
		projectionStatus: input.projectionStatus ?? "superseded",
		githubReviewId: input.githubReviewId ?? null,
	});
}

export async function recordRunResult(
	fingerprint: string,
	input: RecordRunResultInput,
): Promise<void> {
	switch (input.status) {
		case "started":
			if (!input.sessionId) {
				throw new Error("ReviewRun session start requires a session id");
			}
			await markRunSessionStarted(fingerprint, { sessionId: input.sessionId });
			return;
		case "completed":
			await markRunCompleted(fingerprint, {
				sessionId: input.sessionId,
				githubReviewId: input.githubReviewId,
				projectionStatus: input.projectionStatus,
				projectionError: input.projectionError,
				reviewIntent: input.reviewIntent,
			});
			return;
		case "failed":
			await markRunFailed(fingerprint, {
				sessionId: input.sessionId,
				error: input.error ?? "Managed review failed.",
				failureKind: input.failureKind,
				failureRetryable: input.failureRetryable,
				projectionError: input.projectionError,
			});
			return;
		case "superseded":
			await markRunSuperseded(fingerprint, {
				sessionId: input.sessionId,
				reason: input.error ?? "Managed review was superseded.",
				projectionStatus: input.projectionStatus,
				githubReviewId: input.githubReviewId,
			});
			return;
	}
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
	executionState: PrReviewExecutionState;
	latestKnownHeadSha: string;
	failureKind: PrReviewFailureKind | null;
	failureMessage: string | null;
	failureRetryable: boolean | null;
	failedAt: string | null;
	nextAction: string;
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
	reviewIntent: PrReviewRunReviewIntent | null;
	projections: PrReviewProjectionRecord[];
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

export interface BrokerPrReviewRun
	extends Omit<StartedPrReviewRun, "sessionId"> {
	status: PrReviewRunStatus;
	projectionStatus: PrReviewProjectionStatus;
	sessionId: string | null;
	reviewIntent: PrReviewRunReviewIntent | null;
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
	failure_kind: string | null;
	failure_message: string | null;
	failure_retryable: number | null;
	failed_at: string | null;
	projection_status: string | null;
	projection_updated_at: string | null;
	projection_error: string | null;
	github_review_id: string | null;
	review_intent_event: string | null;
	review_intent_body: string | null;
	review_intent_labels: string | null;
	coalesced_head_sha: string | null;
	coalesced_trigger_kind: string | null;
	coalesced_trigger_source_id: string | null;
	coalesced_at: string | null;
}): PrReviewRunDetails {
	const status = row.status as PrReviewRunStatus;
	const projectionStatus = normalizeProjectionStatus(
		row.projection_status,
		status,
	);
	const latestKnownHeadSha = row.coalesced_head_sha ?? row.head_sha;
	const failureKind = normalizeFailureKind(row.failure_kind);
	const failureMessage = sanitizeFailureMessage(
		row.failure_message ?? row.error,
	);
	const projectionError = sanitizeFailureMessage(
		row.projection_error ?? (status === "failed" ? row.error : null),
	);
	const executionState = executionStateForRun({
		status,
		sessionId: row.session_id,
	});
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
		error: failureMessage,
		executionState,
		latestKnownHeadSha,
		failureKind,
		failureMessage,
		failureRetryable:
			row.failure_retryable === null ? null : row.failure_retryable === 1,
		failedAt: row.failed_at,
		nextAction: nextActionForRun({
			status,
			sessionId: row.session_id,
			projectionStatus,
			failureRetryable:
				row.failure_retryable === null ? null : row.failure_retryable === 1,
			coalescedAt: row.coalesced_at,
		}),
		projectionStatus,
		projectionUpdatedAt: row.projection_updated_at ?? row.updated_at,
		projectionError,
		githubReviewId: row.github_review_id,
		reviewIntent: reviewIntentFromRow(row),
		coalescedHeadSha: row.coalesced_head_sha,
		coalescedTriggerKind: row.coalesced_trigger_kind,
		coalescedTriggerSourceId: row.coalesced_trigger_source_id,
		coalescedAt: row.coalesced_at,
		projections: [],
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

	if (!row) return null;
	const run = mapRunDetails(row);
	return {
		...run,
		projections: await listPrReviewProjectionsForRun(run.fingerprint),
	};
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

	if (!row) return null;
	const run = mapRunDetails(row);
	return {
		...run,
		projections: await listPrReviewProjectionsForRun(run.fingerprint),
	};
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
			"failure_kind",
			"failure_message",
			"failure_retryable",
			"failed_at",
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
		const projectionStatus = normalizeProjectionStatus(
			row.projection_status,
			status,
		);
		const failureRetryable =
			row.failure_retryable === null ? null : row.failure_retryable === 1;
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
			error: sanitizeFailureMessage(row.failure_message ?? row.error),
			executionState: executionStateForRun({
				status,
				sessionId: row.session_id,
			}),
			latestKnownHeadSha: row.coalesced_head_sha ?? row.head_sha,
			failureKind: normalizeFailureKind(row.failure_kind),
			failureMessage: sanitizeFailureMessage(row.failure_message ?? row.error),
			failureRetryable,
			failedAt: row.failed_at,
			nextAction: nextActionForRun({
				status,
				sessionId: row.session_id,
				projectionStatus,
				failureRetryable,
				coalescedAt: row.coalesced_at,
			}),
			projectionStatus,
			projectionUpdatedAt: row.projection_updated_at ?? row.updated_at,
			projectionError: sanitizeFailureMessage(
				row.projection_error ?? (status === "failed" ? row.error : null),
			),
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

function mapBrokerRun(row: {
	fingerprint: string;
	repo_full_name: string;
	pr_number: number;
	head_sha: string;
	trigger_kind: string;
	trigger_source_id: string;
	status: string;
	session_id: string | null;
	created_at: string;
	updated_at: string;
	projection_status: string | null;
	review_intent_event: string | null;
	review_intent_body: string | null;
	review_intent_labels: string | null;
	coalesced_head_sha: string | null;
	coalesced_trigger_kind: string | null;
	coalesced_trigger_source_id: string | null;
	coalesced_at: string | null;
}): BrokerPrReviewRun {
	const status = row.status as PrReviewRunStatus;
	return {
		fingerprint: row.fingerprint,
		repoFullName: row.repo_full_name,
		prNumber: row.pr_number,
		headSha: row.head_sha,
		triggerKind: row.trigger_kind,
		triggerSourceId: row.trigger_source_id,
		status,
		projectionStatus: normalizeProjectionStatus(row.projection_status, status),
		sessionId: row.session_id,
		createdAt: row.created_at,
		updatedAt: row.updated_at,
		reviewIntent: reviewIntentFromRow(row),
		coalescedHeadSha: row.coalesced_head_sha,
		coalescedTriggerKind: row.coalesced_trigger_kind,
		coalescedTriggerSourceId: row.coalesced_trigger_source_id,
		coalescedAt: row.coalesced_at,
	};
}

const BROKER_RUN_COLUMNS = [
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
	"projection_status",
	"review_intent_event",
	"review_intent_body",
	"review_intent_labels",
	"coalesced_head_sha",
	"coalesced_trigger_kind",
	"coalesced_trigger_source_id",
	"coalesced_at",
] as const;

export async function listPrReviewRunsForBroker(
	input: {
		limit?: number;
		repoFullName?: string;
	} = {},
): Promise<BrokerPrReviewRun[]> {
	await ensureRunsTable();
	const limit = input.limit ?? 10;
	let startedQuery = getDb()
		.selectFrom("managed_pr_review_runs")
		.select(BROKER_RUN_COLUMNS)
		.where("status", "=", "started")
		.where("session_id", "is not", null);
	let completedQuery = getDb()
		.selectFrom("managed_pr_review_runs")
		.select(BROKER_RUN_COLUMNS)
		.where("status", "=", "completed")
		.where("projection_status", "in", ["pending", "failed"]);
	if (input.repoFullName) {
		startedQuery = startedQuery.where(
			"repo_full_name",
			"=",
			input.repoFullName,
		);
		completedQuery = completedQuery.where(
			"repo_full_name",
			"=",
			input.repoFullName,
		);
	}

	const [startedRows, completedRows] = await Promise.all([
		startedQuery.orderBy("updated_at", "asc").limit(limit).execute(),
		completedQuery
			.orderBy("projection_updated_at", "asc")
			.limit(limit)
			.execute(),
	]);

	return [...startedRows, ...completedRows]
		.map(mapBrokerRun)
		.sort((a, b) => {
			const updated = a.updatedAt.localeCompare(b.updatedAt);
			return updated === 0
				? a.fingerprint.localeCompare(b.fingerprint)
				: updated;
		})
		.slice(0, limit);
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
	projectionsMigrated = false;
}
