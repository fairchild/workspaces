import crypto from "node:crypto";
import {
	type ClassifiedPrReviewRun,
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
		createdAt: run.createdAt,
		updatedAt: run.updatedAt,
		detailsUrl: reviewRunDetailsUrl(requestUrl, run.fingerprint),
		...(run.error ? { error: run.error } : {}),
		...(run.projectionError ? { projectionError: run.projectionError } : {}),
		...(run.githubReviewId ? { githubReviewId: run.githubReviewId } : {}),
	};
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
			missingRuns: 0,
			attentionRequired: 0,
			starting: 0,
			stuckStarting: 0,
			executing: 0,
			needsProjection: 0,
			failed: 0,
			terminal: 0,
			runStates: {
				starting: 0,
				stuckStarting: 0,
				executing: 0,
				needsProjection: 0,
				failed: 0,
				terminal: 0,
			},
			missing: [],
			runs: {
				starting: [],
				stuckStarting: [],
				executing: [],
				needsProjection: [],
				failed: [],
				terminal: [],
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

	const runs = await listRecentPrReviewRuns({ sinceIso, repoFullName });
	const runBuckets = bucketPrReviewRuns(runs, {
		thresholds: { startingTimeoutMinutes, projectionTimeoutMinutes },
	});
	const missing = expectedRuns.filter(
		(expected) =>
			!runs.some(
				(run) =>
					run.repoFullName === expected.repoFullName &&
					run.prNumber === expected.prNumber &&
					(!expected.headSha || run.headSha === expected.headSha) &&
					run.triggerKind === expected.triggerKind &&
					run.triggerSourceId === expected.triggerSourceId,
			),
	);
	const attentionRequired =
		missing.length +
		runBuckets.stuckStarting.length +
		runBuckets.needsProjection.length +
		runBuckets.failed.length;
	const ok = attentionRequired === 0;

	return Response.json(
		{
			ok,
			disabled: false,
			repo: repoFullName,
			windowMinutes,
			startingTimeoutMinutes,
			projectionTimeoutMinutes,
			since: sinceIso,
			checked: expectedRuns.length,
			eligibleEvents: expectedRuns.length,
			missingRuns: missing.length,
			attentionRequired,
			starting: runBuckets.starting.length,
			stuckStarting: runBuckets.stuckStarting.length,
			executing: runBuckets.executing.length,
			needsProjection: runBuckets.needsProjection.length,
			failed: runBuckets.failed.length,
			terminal: runBuckets.terminal.length,
			runStates: {
				starting: runBuckets.starting.length,
				stuckStarting: runBuckets.stuckStarting.length,
				executing: runBuckets.executing.length,
				needsProjection: runBuckets.needsProjection.length,
				failed: runBuckets.failed.length,
				terminal: runBuckets.terminal.length,
			},
			missing,
			runs: {
				starting: runBuckets.starting.map((run) => operatorRunItem(url, run)),
				stuckStarting: runBuckets.stuckStarting.map((run) =>
					operatorRunItem(url, run),
				),
				executing: runBuckets.executing.map((run) => operatorRunItem(url, run)),
				needsProjection: runBuckets.needsProjection.map((run) =>
					operatorRunItem(url, run),
				),
				failed: runBuckets.failed.map((run) => operatorRunItem(url, run)),
				terminal: runBuckets.terminal.map((run) => operatorRunItem(url, run)),
			},
		},
		{ status: ok ? 200 : 503 },
	);
}
