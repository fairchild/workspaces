/*
 * GET /api/pairing/redeemed?next=<path> — the sign-in bounce. Local-mode
 * sign-in redirects here (cookie freshly set) so ANY successful QR
 * redemption — the native app's scanner or a plain camera-to-Safari scan —
 * records the pairing ack before continuing to `next`. Loopback redemptions
 * (the desktop's own embedded webview) are deliberately not recorded: they
 * are not a phone pairing. Gated by the ordinary middleware cookie check.
 */
import type { NextRequest } from "next/server";
import { LOCAL_AUTH_COOKIE, localModeEnabled, localSessionCookieValid } from "@/lib/auth/config";
import { isLoopbackHostHeader } from "@/lib/auth/config";
import { safeRedirectPath } from "@/lib/auth/redirect-path";
import { writePairingAck } from "@/lib/pairing/ack-store";

export const runtime = "nodejs";

export async function GET(request: NextRequest): Promise<Response> {
	if (!localModeEnabled()) {
		return Response.json({ error: "pairing is a local-mode feature" }, { status: 404 });
	}
	if (!localSessionCookieValid(request.cookies.get(LOCAL_AUTH_COOKIE)?.value)) {
		return Response.json({ error: "not signed in" }, { status: 401 });
	}
	if (!isLoopbackHostHeader(request.headers.get("host"))) {
		await writePairingAck(request.headers.get("user-agent"), "sign-in");
	}
	const next = safeRedirectPath(request.nextUrl.searchParams.get("next"));
	// Relative Location on purpose: the server's own request.url carries the
	// loopback bind host, and reconstructing the proxied origin here would
	// re-open the redirect-to-loopback defect the review closed.
	return new Response(null, { status: 307, headers: { location: next } });
}
