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
	parseExtraLocalOrigins,
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
// /api/pairing/ack is the pairing handshake: POST self-authenticates with
// the minted token in its body, GET returns only the latest ack timestamp
// (the desktop pairing window polls it pre-cookie). Exact-match, like
// healthz, so nested paths never inherit the bypass.
const PUBLIC_EXACT_PATHS = new Set(["/api/healthz", "/api/pairing/ack"]);

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
			const nextPath =
				resolved.origin === localOrigin
					? `${resolved.pathname}${resolved.search}`
					: "/";
			// With pairing unconfigured (no extra origins), sign-in behaves
			// byte-identically to the pre-pairing app: straight to the
			// destination. Configured, it bounces through the redemption route
			// so any successful QR sign-in — native scanner and camera-app
			// Safari alike — records the pairing ack first.
			const destination =
				parseExtraLocalOrigins().size === 0
					? new URL(nextPath, localOrigin)
					: new URL(
							`/api/pairing/redeemed?next=${encodeURIComponent(nextPath)}`,
							localOrigin,
						);
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
		if (localSessionCookieValid(request.cookies.get(LOCAL_AUTH_COOKIE)?.value)) {
			return NextResponse.next();
		}
		// Unauthenticated in local mode: API callers get the same 401 JSON;
		// a page redirects to /sign-in on the *resolved* origin, so a request
		// proxied in over the tailnet is never bounced to the server's own
		// loopback bind (which on the phone is the phone itself) (codex review).
		return isApiPath(pathname)
			? unauthorizedJson()
			: NextResponse.redirect(new URL("/sign-in", localOrigin));
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

/*
 * Two entries, because they answer two different questions.
 *
 * `/api/:path*` is unconditional: no static asset lives under /api, so every
 * API request reaches the gate whatever its path looks like. That belt does
 * not depend on getting an extension list right, which matters most for
 * /api/auth/* — in local mode the Host gate runs before isPublic(), so it is
 * the only edge check in front of the route that mints sessions.
 *
 * The second entry covers pages and skips the static assets the exclusion was
 * always for. It tests for a real asset extension at the end of the path
 * rather than "contains a dot": the old `.*\..*` alternative excluded every
 * dotted path in the app, so a dotted API or page path silently skipped the
 * local-mode Host gate and the session-freshness check (#1467). Next
 * statically analyzes this array at build time, so it stays a literal —
 * middleware.matcher.test.ts compiles it with Next's own getMiddlewareMatchers
 * and asserts both halves.
 */
export const config = {
	matcher: [
		"/api/:path*",
		"/((?!api|_next/static|_next/image|favicon\\.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|avif|ico|bmp|css|js|mjs|map|txt|xml|webmanifest|woff|woff2|ttf|otf|eot|wasm|mp4|webm|pdf)$).*)",
	],
};
