import crypto from "node:crypto";
import {
	type ClassifiedPrReviewRun,
	type PrReviewRunSummary,
	bucketPrReviewRuns,
	listRecentPrReviewRuns,
} from "@/lib/agent-runtime/pr-review-runs";
import { parsePrReviewTrigger } from "@/lib/agent-runtime/pr-review-trigger";
import { getDb } from "@/lib/db";

export const dynamic = "force-dynamic";

const SECRET_HEADER = "x-workspace-webhook-canary";
const DEFAULT_REPO = "fairchild/workspaces";
const DEFAULT_WINDOW_MINUTES = 90;
const DEFAULT_STARTING_TIMEOUT_MINUTES = 5;
const DEFAULT_RUNNING_TIMEOUT_MINUTES = 45;
const DEFAULT_PROJECTION_TIMEOUT_MINUTES = 30;
const MAX_WINDOW_MINUTES = 24 * 60;

interface ExpectedRun {
	eventId: string;
	timestamp: string;
	repoFullName: string;
	prNumber: number;
	headSha: string;
	triggerKind: string;
	triggerSourceId: string;
}

interface ExpectedRunGroup {
	key: string;
	eventIds: string[];
	eventCount: number;
	firstTimestamp: string;
	lastTimestamp: string;
	repoFullName: string;
	prNumber: number;
	headSha: string;
	triggerKind: string;
	triggerSourceId: string;
}

interface OperatorRunItem {
	fingerprint: string;
	repoFullName: string;
	prNumber: number;
	headSha: string;
	shortHeadSha: string;
	triggerKind: string;
	triggerSourceId: string;
	status: string;
	agentStatus: string;
	projectionStatus: string;
	projectionUpdatedAt: string;
	projectionError?: string;
	githubReviewId?: string;
	state: string;
	sessionId: string | null;
	ageMinutes: number;
	pickupLatencyMinutes: number | null;
	executionDurationMinutes: number | null;
	projectionLatencyMinutes: number | null;
	sloBreached: boolean;
	createdAt: string;
	updatedAt: string;
	detailsUrl: string;
	error?: string;
}

function timingSafeStringEqual(actual: string, expected: string): boolean {
	if (actual.length !== expected.length) return false;
	return crypto.timingSafeEqual(Buffer.from(actual), Buffer.from(expected));
}

function secretFromRequest(request: Request): string | null {
	const bearer = request.headers.get("authorization");
	if (bearer?.toLowerCase().startsWith("bearer ")) {
		return bearer.slice("bearer ".length).trim();
	}
	return request.headers.get(SECRET_HEADER);
}

function authenticate(request: Request): Response | null {
	const expected = process.env.WORKSPACES_WEBHOOK_CANARY_SECRET;
	if (!expected) {
		return Response.json(
			{ ok: false, error: "monitor_not_configured" },
			{ status: 404 },
		);
	}

	const provided = secretFromRequest(request);
	if (!provided || !timingSafeStringEqual(provided, expected)) {
		return Response.json({ ok: false, error: "unauthorized" }, { status: 401 });
	}

	return null;
}

function windowMinutesFromUrl(url: URL): number {
	const raw = Number(url.searchParams.get("windowMinutes") ?? "");
	if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_WINDOW_MINUTES;
	return Math.min(Math.floor(raw), MAX_WINDOW_MINUTES);
}

function timeoutMinutesFromUrl(
	url: URL,
	name: string,
	defaultValue: number,
): number {
	const raw = Number(url.searchParams.get(name) ?? "");
	if (!Number.isFinite(raw) || raw <= 0) return defaultValue;
	return Math.min(Math.floor(raw), MAX_WINDOW_MINUTES);
}

function reviewRunDetailsUrl(requestUrl: URL, fingerprint: string): string {
	return `${requestUrl.origin}/dashboard/review-runs/${encodeURIComponent(fingerprint)}`;
}

function operatorRunItem(
	requestUrl: URL,
	run: ClassifiedPrReviewRun,
): OperatorRunItem {
	return {
		fingerprint: run.fingerprint,
		repoFullName: run.repoFullName,
		prNumber: run.prNumber,
		headSha: run.headSha,
		shortHeadSha: run.headSha.slice(0, 7) || "-",
		triggerKind: run.triggerKind,
		triggerSourceId: run.triggerSourceId,
		status: run.status,
		agentStatus: run.status,
		projectionStatus: run.projectionStatus,
		projectionUpdatedAt: run.projectionUpdatedAt,
		state: run.state,
		sessionId: run.sessionId,
		ageMinutes: run.ageMinutes,
		pickupLatencyMinutes: run.pickupLatencyMinutes,
		executionDurationMinutes: run.executionDurationMinutes,
		projectionLatencyMinutes: run.projectionLatencyMinutes,
		sloBreached: run.sloBreached,
		createdAt: run.createdAt,
		updatedAt: run.updatedAt,
		detailsUrl: reviewRunDetailsUrl(requestUrl, run.fingerprint),
		...(run.error ? { error: run.error } : {}),
		...(run.projectionError ? { projectionError: run.projectionError } : {}),
		...(run.githubReviewId ? { githubReviewId: run.githubReviewId } : {}),
	};
}

function expectedRunGroupKey(expected: ExpectedRun): string {
	return [
		expected.repoFullName,
		String(expected.prNumber),
		expected.headSha || "*",
	].join("|");
}

function groupExpectedRuns(expectedRuns: ExpectedRun[]): ExpectedRunGroup[] {
	const groups = new Map<string, ExpectedRunGroup>();
	for (const expected of [...expectedRuns].sort((a, b) =>
		a.timestamp.localeCompare(b.timestamp),
	)) {
		const key = expectedRunGroupKey(expected);
		const existing = groups.get(key);
		if (existing) {
			existing.eventIds.push(expected.eventId);
			existing.eventCount += 1;
			existing.lastTimestamp = expected.timestamp;
			existing.triggerKind = expected.triggerKind;
			existing.triggerSourceId = expected.triggerSourceId;
			continue;
		}
		groups.set(key, {
			key,
			eventIds: [expected.eventId],
			eventCount: 1,
			firstTimestamp: expected.timestamp,
			lastTimestamp: expected.timestamp,
			repoFullName: expected.repoFullName,
			prNumber: expected.prNumber,
			headSha: expected.headSha,
			triggerKind: expected.triggerKind,
			triggerSourceId: expected.triggerSourceId,
		});
	}
	return [...groups.values()];
}

function runCoversExpectedGroup(
	run: PrReviewRunSummary,
	expected: ExpectedRunGroup,
): boolean {
	if (
		run.repoFullName !== expected.repoFullName ||
		run.prNumber !== expected.prNumber
	) {
		return false;
	}
	if (!expected.headSha) return true;
	return (
		run.headSha === expected.headSha ||
		run.latestKnownHeadSha === expected.headSha ||
		run.coalescedHeadSha === expected.headSha
	);
}

function maxMetric(values: Array<number | null>): number | null {
	const present = values.filter((value): value is number => value !== null);
	return present.length ? Math.max(...present) : null;
}

function runItems(
	requestUrl: URL,
	runs: ClassifiedPrReviewRun[],
): OperatorRunItem[] {
	return runs.map((run) => operatorRunItem(requestUrl, run));
}

function expectedRunFromWebhookEvent(row: {
	id: string;
	type: string;
	action: string;
	timestamp: string;
	payload: string;
}): ExpectedRun | null {
	let payload: Record<string, unknown>;
	try {
		payload = JSON.parse(row.payload) as Record<string, unknown>;
	} catch {
		return null;
	}

	const trigger = parsePrReviewTrigger(row.type, row.action, payload);
	if (!trigger) return null;

	return {
		eventId: row.id,
		timestamp: row.timestamp,
		repoFullName: trigger.reviewPayload.repoFullName,
		prNumber: trigger.reviewPayload.number,
		headSha: trigger.reviewPayload.headSha,
		triggerKind: trigger.context.kind,
		triggerSourceId: trigger.context.triggerSourceId,
	};
}

export async function GET(request: Request): Promise<Response> {
	const authFailure = authenticate(request);
	if (authFailure) return authFailure;

	if (process.env.PR_REVIEWER_ENABLED === "0") {
		return Response.json({
			ok: true,
			disabled: true,
			checked: 0,
			eligibleEvents: 0,
			eligibleRunKeys: 0,
			missingRuns: 0,
			missingRunKeys: 0,
			attentionRequired: 0,
			health: "disabled",
			starting: 0,
			stuckStarting: 0,
			running: 0,
			runningTooLong: 0,
			completedAwaitingProjection: 0,
			failedExecution: 0,
			projectionFailed: 0,
			superseded: 0,
			published: 0,
			failedRunCount: 0,
			projectionFailedCount: 0,
			staleRunCount: 0,
			supersededRunCount: 0,
			staleOrSupersededCount: 0,
			runStates: {
				starting: 0,
				stuckStarting: 0,
				running: 0,
				runningTooLong: 0,
				completedAwaitingProjection: 0,
				failedExecution: 0,
				projectionFailed: 0,
				superseded: 0,
				published: 0,
			},
			slo: {
				pickupTimeoutMinutes: DEFAULT_STARTING_TIMEOUT_MINUTES,
				runningTimeoutMinutes: DEFAULT_RUNNING_TIMEOUT_MINUTES,
				projectionTimeoutMinutes: DEFAULT_PROJECTION_TIMEOUT_MINUTES,
				maxPickupLatencyMinutes: null,
				maxExecutionDurationMinutes: null,
				maxProjectionLatencyMinutes: null,
			},
			reviewRunHealth: {
				status: "disabled",
				missingRunKeys: 0,
				unhealthyRunCount: 0,
				degradedRunCount: 0,
			},
			githubProjectionAudit: {
				status: "not_checked",
				script: "scripts/pr-review-health.py",
			},
			missing: [],
			runs: {
				starting: [],
				stuckStarting: [],
				running: [],
				runningTooLong: [],
				completedAwaitingProjection: [],
				failedExecution: [],
				projectionFailed: [],
				superseded: [],
				published: [],
			},
		});
	}

	const url = new URL(request.url);
	const repoFullName = url.searchParams.get("repo") ?? DEFAULT_REPO;
	const windowMinutes = windowMinutesFromUrl(url);
	const startingTimeoutMinutes = timeoutMinutesFromUrl(
		url,
		"startingTimeoutMinutes",
		DEFAULT_STARTING_TIMEOUT_MINUTES,
	);
	const runningTimeoutMinutes = timeoutMinutesFromUrl(
		url,
		"runningTimeoutMinutes",
		DEFAULT_RUNNING_TIMEOUT_MINUTES,
	);
	const projectionTimeoutMinutes = timeoutMinutesFromUrl(
		url,
		"projectionTimeoutMinutes",
		DEFAULT_PROJECTION_TIMEOUT_MINUTES,
	);
	const sinceIso = new Date(
		Date.now() - windowMinutes * 60 * 1000,
	).toISOString();

	const webhookRows = await getDb()
		.selectFrom("webhook_events")
		.select(["id", "type", "action", "timestamp", "payload"])
		.where("timestamp", ">=", sinceIso)
		.where("repo", "=", repoFullName)
		.execute();
	const expectedRuns = webhookRows
		.map(expectedRunFromWebhookEvent)
		.filter((entry): entry is ExpectedRun => Boolean(entry));
	const expectedRunGroups = groupExpectedRuns(expectedRuns);

	const runs = await listRecentPrReviewRuns({ sinceIso, repoFullName });
	const runBuckets = bucketPrReviewRuns(runs, {
		thresholds: {
			startingTimeoutMinutes,
			runningTimeoutMinutes,
			projectionTimeoutMinutes,
		},
	});
	const missing = expectedRunGroups.filter(
		(expected) => !runs.some((run) => runCoversExpectedGroup(run, expected)),
	);
	const staleCompletedAwaitingProjection =
		runBuckets.completedAwaitingProjection.filter((run) => run.sloBreached);
	const unhealthyRunCount =
		runBuckets.stuckStarting.length +
		runBuckets.runningTooLong.length +
		runBuckets.failedExecution.length +
		runBuckets.projectionFailed.length +
		staleCompletedAwaitingProjection.length;
	const degradedRunCount =
		runBuckets.completedAwaitingProjection.length -
		staleCompletedAwaitingProjection.length;
	const attentionRequired = missing.length + unhealthyRunCount;
	const health =
		attentionRequired > 0
			? "unhealthy"
			: degradedRunCount > 0
				? "degraded"
				: "healthy";
	const ok = health !== "unhealthy";
	const allClassifiedRuns = [
		...runBuckets.starting,
		...runBuckets.stuckStarting,
		...runBuckets.running,
		...runBuckets.runningTooLong,
		...runBuckets.completedAwaitingProjection,
		...runBuckets.failedExecution,
		...runBuckets.projectionFailed,
		...runBuckets.superseded,
		...runBuckets.published,
	];
	const staleRunCount =
		runBuckets.stuckStarting.length +
		runBuckets.runningTooLong.length +
		staleCompletedAwaitingProjection.length;
	const supersededRunCount = runBuckets.superseded.length;

	return Response.json(
		{
			ok,
			disabled: false,
			health,
			repo: repoFullName,
			windowMinutes,
			startingTimeoutMinutes,
			runningTimeoutMinutes,
			projectionTimeoutMinutes,
			since: sinceIso,
			checked: expectedRunGroups.length,
			eligibleEvents: expectedRuns.length,
			eligibleRunKeys: expectedRunGroups.length,
			missingRuns: missing.length,
			missingRunKeys: missing.length,
			attentionRequired,
			starting: runBuckets.starting.length,
			stuckStarting: runBuckets.stuckStarting.length,
			running: runBuckets.running.length,
			runningTooLong: runBuckets.runningTooLong.length,
			completedAwaitingProjection:
				runBuckets.completedAwaitingProjection.length,
			failedExecution: runBuckets.failedExecution.length,
			projectionFailed: runBuckets.projectionFailed.length,
			superseded: runBuckets.superseded.length,
			published: runBuckets.published.length,
			failedRunCount: runBuckets.failedExecution.length,
			projectionFailedCount: runBuckets.projectionFailed.length,
			staleRunCount,
			supersededRunCount,
			staleOrSupersededCount: staleRunCount + supersededRunCount,
			runStates: {
				starting: runBuckets.starting.length,
				stuckStarting: runBuckets.stuckStarting.length,
				running: runBuckets.running.length,
				runningTooLong: runBuckets.runningTooLong.length,
				completedAwaitingProjection:
					runBuckets.completedAwaitingProjection.length,
				failedExecution: runBuckets.failedExecution.length,
				projectionFailed: runBuckets.projectionFailed.length,
				superseded: runBuckets.superseded.length,
				published: runBuckets.published.length,
			},
			slo: {
				pickupTimeoutMinutes: startingTimeoutMinutes,
				runningTimeoutMinutes,
				projectionTimeoutMinutes,
				maxPickupLatencyMinutes: maxMetric(
					allClassifiedRuns.map((run) => run.pickupLatencyMinutes),
				),
				maxExecutionDurationMinutes: maxMetric(
					allClassifiedRuns.map((run) => run.executionDurationMinutes),
				),
				maxProjectionLatencyMinutes: maxMetric(
					allClassifiedRuns.map((run) => run.projectionLatencyMinutes),
				),
			},
			reviewRunHealth: {
				status: health,
				missingRunKeys: missing.length,
				unhealthyRunCount,
				degradedRunCount,
				failedRunCount: runBuckets.failedExecution.length,
				projectionFailedCount: runBuckets.projectionFailed.length,
				staleRunCount,
				supersededRunCount,
				staleOrSupersededCount: staleRunCount + supersededRunCount,
			},
			githubProjectionAudit: {
				status: "not_checked",
				script: "scripts/pr-review-health.py",
				note: "GitHub status/review drift is audited separately from ReviewRun source-of-truth health.",
			},
			missing,
			runs: {
				starting: runItems(url, runBuckets.starting),
				stuckStarting: runItems(url, runBuckets.stuckStarting),
				running: runItems(url, runBuckets.running),
				runningTooLong: runItems(url, runBuckets.runningTooLong),
				completedAwaitingProjection: runItems(
					url,
					runBuckets.completedAwaitingProjection,
				),
				failedExecution: runItems(url, runBuckets.failedExecution),
				projectionFailed: runItems(url, runBuckets.projectionFailed),
				superseded: runItems(url, runBuckets.superseded),
				published: runItems(url, runBuckets.published),
			},
		},
		{ status: ok ? 200 : 503 },
	);
}
