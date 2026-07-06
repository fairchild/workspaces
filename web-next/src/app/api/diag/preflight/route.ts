/*
 * GET /api/diag/preflight — auth-gated environment health check for the #750
 * real runtime. Default run proves model inference, GitHub App clone
 * credentials, and Vercel access (cheap, no sandbox cost). Add `?sandbox=1` to
 * also spin a live Vercel sandbox that runs bash and clones the repo inside it.
 * Never returns secret values — only status and non-secret metadata. Returns
 * 200 when every check passes/skips, 503 otherwise.
 */
import { getAuthState } from "@/lib/auth/auth-state";
import { runPreflight } from "@/lib/diag/preflight";

export const runtime = "nodejs";
export const maxDuration = 300;

export async function GET(request: Request) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const includeSandbox =
		new URL(request.url).searchParams.get("sandbox") === "1";
	const report = await runPreflight({ includeSandbox });
	return Response.json(report, { status: report.ok ? 200 : 503 });
}
