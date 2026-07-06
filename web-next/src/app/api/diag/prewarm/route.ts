/*
 * GET /api/diag/prewarm — auth-gated trigger that builds (or refreshes) the
 * harness sandbox template out of band, so the first real session turn resumes
 * from a snapshot instead of paying the ~1–4 min claude-CLI install inside its
 * own request budget (the chat route caps at maxDuration=300). Idempotent — a
 * fast no-op once the snapshot exists. Hit it once after each deploy that
 * changes the bootstrap recipe. Never returns secret values.
 */
import { getAuthState } from "@/lib/auth/auth-state";
import { prewarmVercelTemplate } from "@/lib/agent-runtime/vercel-provider";

export const runtime = "nodejs";
export const maxDuration = 300;

export async function GET() {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	try {
		const { tookMs } = await prewarmVercelTemplate();
		return Response.json({ ok: true, onVercel: !!process.env.VERCEL, tookMs });
	} catch (error) {
		return Response.json(
			{
				ok: false,
				onVercel: !!process.env.VERCEL,
				error: error instanceof Error ? error.message : String(error),
			},
			{ status: 503 },
		);
	}
}
