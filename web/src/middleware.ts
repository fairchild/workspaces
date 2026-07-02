import { resolveBetterAuthSecret } from "@/lib/agent-runtime/config";
import { evaluateSessionFreshness } from "@/lib/session-cookie";
import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

const PUBLIC_PATHS = new Set([
	"/",
	"/docs",
	"/sign-in",
	"/api/auth",
	"/api/webhooks",
	"/api/workspaces/sync",
]);

function isPublic(pathname: string): boolean {
	if (PUBLIC_PATHS.has(pathname)) return true;
	for (const prefix of PUBLIC_PATHS) {
		if (pathname.startsWith(`${prefix}/`)) return true;
	}
	return false;
}

function redirectToSignIn(
	request: NextRequest,
	pathname: string,
): NextResponse {
	const signInUrl = new URL("/sign-in", request.url);
	signInUrl.searchParams.set("callbackUrl", pathname);
	return NextResponse.redirect(signInUrl);
}

export async function middleware(request: NextRequest) {
	const { pathname } = request.nextUrl;

	if (pathname.startsWith("/docs/") && !pathname.includes(".")) {
		return NextResponse.rewrite(
			new URL("/docs/_renderer/index.html", request.url),
		);
	}

	if (isPublic(pathname)) return NextResponse.next();

	// Allow unauthenticated access on localhost for dev/evidence
	// screenshots — but only when no real OAuth app is configured,
	// so production and OAuth-configured dev still redirect to sign-in.
	if (
		process.env.NODE_ENV === "development" &&
		process.env.DEV_BYPASS_AUTH === "1" &&
		!process.env.GITHUB_WEB_WORKSPACES_CLIENT_ID
	) {
		return NextResponse.next();
	}

	// Validate freshness, not just cookie presence: an absent token, or an
	// expired/tampered/malformed Better Auth cookie cache, redirects straight
	// from the edge instead of rendering the shell and bouncing at layout
	// getSession(). If the secret can't be resolved (misconfig) we fall
	// through so middleware never hard-fails the app; layout getSession()
	// still gates the page.
	let secret: string;
	try {
		secret = resolveBetterAuthSecret();
	} catch {
		return NextResponse.next();
	}

	const freshness = await evaluateSessionFreshness(request, { secret });
	if (freshness === "stale") {
		return redirectToSignIn(request, pathname);
	}

	// "fresh" proceeds; "indeterminate" also proceeds and defers to layout
	// getSession() rather than logging out a possibly-valid idle session.
	return NextResponse.next();
}

export const config = {
	matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\..*).*)"],
};
