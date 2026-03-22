import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

const PUBLIC_PATHS = new Set(["/", "/sign-in", "/api/auth", "/api/webhooks"]);

function isPublic(pathname: string): boolean {
	if (PUBLIC_PATHS.has(pathname)) return true;
	for (const prefix of PUBLIC_PATHS) {
		if (pathname.startsWith(`${prefix}/`)) return true;
	}
	return false;
}

export function middleware(request: NextRequest) {
	const { pathname } = request.nextUrl;

	if (isPublic(pathname)) return NextResponse.next();

	const sessionCookie = request.cookies.get("better-auth.session_token");
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
