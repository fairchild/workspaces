import { recoverPrReviewRun } from "@/lib/agent-runtime/pr-review";
import { getPrReviewRunByFingerprint } from "@/lib/agent-runtime/pr-review-runs";
import { authorizeRepoAccess, unauthorizedResponse } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";

export const dynamic = "force-dynamic";

export async function GET(
	_request: Request,
	{ params }: { params: Promise<{ fingerprint: string }> },
): Promise<Response> {
	const session = await getSession();
	if (!session?.user) return unauthorizedResponse();

	const { fingerprint } = await params;
	const run = await getPrReviewRunByFingerprint(fingerprint);
	if (!run) {
		return Response.json({ error: "review run not found" }, { status: 404 });
	}

	const unauthorized = await authorizeRepoAccess(
		session.user.id,
		run.repoFullName,
	);
	if (unauthorized) return unauthorized;

	return Response.json({ run });
}

export async function POST(
	_request: Request,
	{ params }: { params: Promise<{ fingerprint: string }> },
): Promise<Response> {
	const session = await getSession();
	if (!session?.user) return unauthorizedResponse();

	const { fingerprint } = await params;
	const run = await getPrReviewRunByFingerprint(fingerprint);
	if (!run) {
		return Response.json({ error: "review run not found" }, { status: 404 });
	}

	const unauthorized = await authorizeRepoAccess(
		session.user.id,
		run.repoFullName,
	);
	if (unauthorized) return unauthorized;

	const result = await recoverPrReviewRun(fingerprint);
	return Response.json(result, { status: result.ok ? 200 : result.status });
}
