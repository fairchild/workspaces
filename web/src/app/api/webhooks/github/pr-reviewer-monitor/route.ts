import crypto from "node:crypto";
import { listRecentPrReviewRuns } from "@/lib/agent-runtime/pr-review-runs";
import { parsePrReviewTrigger } from "@/lib/agent-runtime/pr-review-trigger";
import { getDb } from "@/lib/db";

export const dynamic = "force-dynamic";

const SECRET_HEADER = "x-workspace-webhook-canary";
const DEFAULT_REPO = "fairchild/workspaces";
const DEFAULT_WINDOW_MINUTES = 90;
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
			missing: [],
		});
	}

	const url = new URL(request.url);
	const repoFullName = url.searchParams.get("repo") ?? DEFAULT_REPO;
	const windowMinutes = windowMinutesFromUrl(url);
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

	return Response.json(
		{
			ok: missing.length === 0,
			disabled: false,
			repo: repoFullName,
			windowMinutes,
			since: sinceIso,
			checked: expectedRuns.length,
			missing,
		},
		{ status: missing.length === 0 ? 200 : 503 },
	);
}
