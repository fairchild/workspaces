/*
 * Edge gate: everything except sign-in, the auth API, and static assets
 * requires a session. Freshness is verified at the edge (signed cookie
 * cache — see lib/auth/session-cookie.ts) so stale/tampered sessions are
 * refused without rendering the shell or reaching a route handler; the
 * allowlist verdict itself is server-side in getAuthState (it needs the
 * user record). Pages get an HTML redirect to /sign-in; `/api/*` callers
 * get the same JSON shape (`{ error }`, 401) the routes themselves return
 * for an unauthenticated caller, so API clients never have to parse a
 * sign-in page as an error response (#828).
 */
import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import {
	authBypassEnabled,
	LOCAL_AUTH_COOKIE,
	localRequestOrigin,
	localModeEnabled,
	localSessionCookieValid,
	resolveAuthSecret,
	TEST_AUTH_COOKIE,
} from "@/lib/auth/config";
import { safeRedirectPath } from "@/lib/auth/redirect-path";
import { evaluateSessionFreshness } from "@/lib/auth/session-cookie";

const PUBLIC_PATHS = new Set(["/sign-in", "/api/auth"]);

// /api/healthz is the embedded-native readiness probe (#987) — it must answer
// before any sign-in exists, in every auth mode. Exact-match only, so a
// future route nested under it can't silently inherit the auth bypass.
const PUBLIC_EXACT_PATHS = new Set(["/api/healthz"]);

function isPublic(pathname: string): boolean {
	if (PUBLIC_EXACT_PATHS.has(pathname)) return true;
	if (PUBLIC_PATHS.has(pathname)) return true;
	for (const prefix of PUBLIC_PATHS) {
		if (pathname.startsWith(`${prefix}/`)) return true;
	}
	return false;
}

function isApiPath(pathname: string): boolean {
	return pathname === "/api" || pathname.startsWith("/api/");
}

// Same error shape every route handler's own getAuthState gate returns for
// an unauthenticated caller (see e.g. sessions/[id]/chat/route.ts) — the
// edge and the route stay indistinguishable to API clients.
function unauthorizedJson(): NextResponse {
	return NextResponse.json(
		{ error: "not signed in as the allowed user" },
		{ status: 401 },
	);
}

function forbiddenLocalHostJson(): NextResponse {
	return NextResponse.json(
		{ error: "local mode only accepts loopback or allowlisted Host headers" },
		{ status: 403 },
	);
}

function redirectToSignIn(request: NextRequest): NextResponse {
	const signInUrl = new URL("/sign-in", request.url);
	return NextResponse.redirect(signInUrl);
}

// The edge only ever refuses on a missing/stale/tampered session (`stale`
// freshness, or bypass mode's absent test cookie) — it never returns 403;
// the allowlist verdict that can produce "forbidden" is server-side and
// left to getAuthState in the route handler or layout.
function unauthenticatedResponse(request: NextRequest): NextResponse {
	return isApiPath(request.nextUrl.pathname)
		? unauthorizedJson()
		: redirectToSignIn(request);
}

export async function middleware(request: NextRequest) {
	const { pathname } = request.nextUrl;

	if (localModeEnabled()) {
		const localOrigin = localRequestOrigin(
			request.headers.get("host"),
			request.headers.get("x-forwarded-proto"),
		);
		if (!localOrigin) {
			return isApiPath(pathname)
				? forbiddenLocalHostJson()
				: new NextResponse("local mode only accepts loopback or allowlisted Host headers", {
						status: 403,
					});
		}
		const queryToken = request.nextUrl.searchParams.get("token");
		if (pathname === "/sign-in" && localSessionCookieValid(queryToken)) {
			// `redirect` lets the embedded shell land directly on a deep link
			// (#987); safeRedirectPath pins the target to this origin, and the
			// resolved-origin check is the backstop: even if a parser-mangled
			// value slips through the validator (WHATWG strips tab/LF/CR), an
			// off-origin resolution falls back to "/".
			const target = safeRedirectPath(request.nextUrl.searchParams.get("redirect"));
			const resolved = new URL(target, localOrigin);
			const destination =
				resolved.origin === localOrigin ? resolved : new URL("/", localOrigin);
			const response = NextResponse.redirect(destination);
			response.cookies.set(LOCAL_AUTH_COOKIE, queryToken ?? "", {
				path: "/",
				httpOnly: true,
				sameSite: "lax",
				secure: localOrigin.startsWith("https:"),
			});
			return response;
		}
		if (isPublic(pathname)) return NextResponse.next();
		return localSessionCookieValid(request.cookies.get(LOCAL_AUTH_COOKIE)?.value)
			? NextResponse.next()
			: unauthenticatedResponse(request);
	}

	if (isPublic(pathname)) return NextResponse.next();

	// Test bypass (inert in production — see authBypassEnabled): the test
	// cookie is the session. Absent cookie still means signed out, so the
	// unauth response stays testable.
	if (authBypassEnabled()) {
		return request.cookies.has(TEST_AUTH_COOKIE)
			? NextResponse.next()
			: unauthenticatedResponse(request);
	}

	// If the secret can't be resolved (misconfig) fall through so middleware
	// never hard-fails the app; the layout/route gate still refuses access.
	let secret: string;
	try {
		secret = resolveAuthSecret();
	} catch {
		return NextResponse.next();
	}

	const freshness = await evaluateSessionFreshness(request, { secret });
	if (freshness === "stale") return unauthenticatedResponse(request);

	// "fresh" proceeds; "indeterminate" also proceeds and defers to the
	// layout/route gate rather than logging out a possibly-valid idle session.
	return NextResponse.next();
}

export const config = {
	matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\..*).*)"],
};
