/*
 * Edge gate: everything except sign-in, the auth API, and static assets
 * requires a session. Freshness is verified at the edge (signed cookie
 * cache — see lib/auth/session-cookie.ts) so stale/tampered sessions
 * redirect without rendering the shell; the allowlist verdict itself is
 * server-side in getAuthState (it needs the user record).
 */
import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import {
	authBypassEnabled,
	resolveAuthSecret,
	TEST_AUTH_COOKIE,
} from "@/lib/auth/config";
import { evaluateSessionFreshness } from "@/lib/auth/session-cookie";

const PUBLIC_PATHS = new Set(["/sign-in", "/api/auth"]);

function isPublic(pathname: string): boolean {
	if (PUBLIC_PATHS.has(pathname)) return true;
	for (const prefix of PUBLIC_PATHS) {
		if (pathname.startsWith(`${prefix}/`)) return true;
	}
	return false;
}

function redirectToSignIn(request: NextRequest): NextResponse {
	const signInUrl = new URL("/sign-in", request.url);
	return NextResponse.redirect(signInUrl);
}

export async function middleware(request: NextRequest) {
	const { pathname } = request.nextUrl;
	if (isPublic(pathname)) return NextResponse.next();

	// Test bypass (inert in production — see authBypassEnabled): the test
	// cookie is the session. Absent cookie still means signed out, so the
	// unauth redirect stays testable.
	if (authBypassEnabled()) {
		return request.cookies.has(TEST_AUTH_COOKIE)
			? NextResponse.next()
			: redirectToSignIn(request);
	}

	// If the secret can't be resolved (misconfig) fall through so middleware
	// never hard-fails the app; the layout gate still refuses access.
	let secret: string;
	try {
		secret = resolveAuthSecret();
	} catch {
		return NextResponse.next();
	}

	const freshness = await evaluateSessionFreshness(request, { secret });
	if (freshness === "stale") return redirectToSignIn(request);

	// "fresh" proceeds; "indeterminate" also proceeds and defers to the layout
	// gate rather than logging out a possibly-valid idle session.
	return NextResponse.next();
}

export const config = {
	matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\..*).*)"],
};
