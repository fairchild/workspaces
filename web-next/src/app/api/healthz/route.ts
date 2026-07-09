/*
 * GET /api/healthz — the embedded-native readiness probe (#987): the native
 * shell spawns `pnpm start:local`, polls this until it answers, then navigates
 * its webview to the minted sign-in URL. Unauthenticated in every auth mode
 * (middleware allowlists it) and deliberately constant — no version, user, or
 * db state — so a pre-auth caller learns nothing but "up, and which mode".
 */
import { localModeEnabled } from "@/lib/auth/config";

export const runtime = "nodejs";

export function GET(): Response {
	return Response.json({ ok: true, localMode: localModeEnabled() });
}
