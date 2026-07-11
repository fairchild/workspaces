/*
 * GET /api/diag/preflight — auth-gated, provider-aware runtime health check.
 * Vercel targets prove model/GitHub/Vercel access; host targets prove local
 * Claude, git, and the owned workspace root. Add `?sandbox=1` to a Vercel
 * target to spin a live sandbox that runs bash and clones the repo inside it.
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
