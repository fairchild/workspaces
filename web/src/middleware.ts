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

export function middleware(request: NextRequest) {
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

	const sessionCookie =
		request.cookies.get("better-auth.session_token") ??
		request.cookies.get("__Secure-better-auth.session_token");
	if (!sessionCookie?.value) {
		const signInUrl = new URL("/sign-in", request.url);
		signInUrl.searchParams.set("callbackUrl", pathname);
		return NextResponse.redirect(signInUrl);
	}

	return NextResponse.next();
}

export const config = {
	matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\..*).*)"],
};
