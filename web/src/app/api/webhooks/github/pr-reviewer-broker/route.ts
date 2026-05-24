import crypto from "node:crypto";
import { processPendingPrReviewRuns } from "@/lib/agent-runtime/pr-review";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

const SECRET_HEADER = "x-workspace-webhook-canary";
const DEFAULT_LIMIT = 5;
const MAX_LIMIT = 20;

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
			{ ok: false, error: "broker_not_configured" },
			{ status: 404 },
		);
	}

	const provided = secretFromRequest(request);
	if (!provided || !timingSafeStringEqual(provided, expected)) {
		return Response.json({ ok: false, error: "unauthorized" }, { status: 401 });
	}

	return null;
}

function limitFromUrl(url: URL): number {
	const raw = Number(url.searchParams.get("limit") ?? "");
	if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_LIMIT;
	return Math.min(Math.floor(raw), MAX_LIMIT);
}

export async function POST(request: Request): Promise<Response> {
	const authFailure = authenticate(request);
	if (authFailure) return authFailure;

	if (process.env.PR_REVIEWER_ENABLED === "0") {
		return Response.json({ ok: true, disabled: true, checked: 0 });
	}

	const url = new URL(request.url);
	const result = await processPendingPrReviewRuns({
		limit: limitFromUrl(url),
		repoFullName: url.searchParams.get("repo") ?? undefined,
	});

	return Response.json({ ok: result.failed === 0, ...result });
}
