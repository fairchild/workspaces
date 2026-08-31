/*
 * POST /sign-out — the local-mode exit (#1488). The owner-local session lives
 * in an HttpOnly cookie, so script cannot end the session; only a Set-Cookie
 * can. This expires it and sends the browser to /sign-in, which then renders
 * the door instead of bouncing home. One cookie is the whole exit: the other
 * two identities are inert while local mode is on — authBypassEnabled() is
 * false by construction, and the OAuth env is refused alongside it.
 *
 * Ordinarily middleware-gated rather than public: a caller without a valid
 * local session is already redirected to /sign-in at the edge, so "sign out
 * when signed out" lands on the sign-in page for free. The handler carries no
 * auth gate of its own — signing out grants nothing — and POST-only plus
 * SameSite=Lax means a cross-site request arrives without the cookie anyway.
 */
import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import {
	LOCAL_AUTH_COOKIE,
	localModeEnabled,
	localRequestOrigin,
} from "@/lib/auth/config";

export const runtime = "nodejs";

export async function POST(request: NextRequest): Promise<Response> {
	if (!localModeEnabled()) {
		return Response.json({ error: "sign-out is a local-mode route" }, { status: 404 });
	}
	// Relative Location, for the reason /api/pairing/redeemed gives: the
	// server's own request.url carries the loopback bind, so an absolute
	// target would send a phone signed in over the tailnet to its own
	// localhost. 303 so the browser follows with a GET.
	const response = new NextResponse(null, {
		status: 303,
		headers: { location: "/sign-in" },
	});
	// Attributes mirror the mint (middleware and the sign-in action) so the
	// expiry lands on the same cookie in both serving shapes — plain-http
	// loopback and the https tailnet origin.
	const origin = localRequestOrigin(
		request.headers.get("host"),
		request.headers.get("x-forwarded-proto"),
	);
	response.cookies.set(LOCAL_AUTH_COOKIE, "", {
		path: "/",
		httpOnly: true,
		sameSite: "lax",
		secure: origin?.startsWith("https:") ?? false,
		maxAge: 0,
	});
	return response;
}
