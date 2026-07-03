/*
 * Edge-safe session freshness check for middleware, ported from
 * web/src/lib/session-cookie.ts (the lesson it encodes: gate on a *verified*
 * cookie, not cookie presence). It checks the short-TTL, HMAC-signed Better
 * Auth cookie cache (`session_data`) via `getCookieCache` — Web Crypto only,
 * no Node imports — so expired/tampered sessions redirect straight from the
 * edge instead of flashing the app shell and bouncing at layout getSession().
 */
import { getCookieCache } from "better-auth/cookies";

const SESSION_TOKEN_COOKIES = [
	"better-auth.session_token",
	"__Secure-better-auth.session_token",
] as const;

const SESSION_DATA_PLAIN = "better-auth.session_data";
const SESSION_DATA_SECURE = "__Secure-better-auth.session_data";

/**
 * The middleware-relevant verdict for the request's session cookies.
 *
 * - `fresh` — the cookie cache verified and is unexpired; let the request through.
 * - `stale` — no session token, or a present cookie cache is expired, tampered,
 *   or malformed; redirect to sign-in.
 * - `indeterminate` — freshness cannot be decided at the edge (cookie-cache TTL
 *   lapsed while the longer-lived token may still be valid, or verification
 *   errored); fall through and let the layout's getAuthState() make the call so
 *   middleware never hard-fails the app.
 */
export type SessionFreshness = "fresh" | "stale" | "indeterminate";

function cookieHeader(request: Request): string {
	return request.headers.get("cookie") ?? "";
}

function hasCookie(header: string, name: string): boolean {
	return header.split(";").some((pair) => pair.trim().startsWith(`${name}=`));
}

/**
 * Evaluate the freshness of the Better Auth session cookies on `request`
 * without a database round-trip. Pure and edge-runtime compatible: it only
 * reads the request's `cookie` header and verifies the signed cookie cache
 * with Web Crypto via `getCookieCache`.
 */
export async function evaluateSessionFreshness(
	request: Request,
	options: { secret: string },
): Promise<SessionFreshness> {
	const header = cookieHeader(request);

	// Absent session token → redirect.
	if (!SESSION_TOKEN_COOKIES.some((name) => hasCookie(header, name))) {
		return "stale";
	}

	const hasSecureData = hasCookie(header, SESSION_DATA_SECURE);
	const hasPlainData = hasCookie(header, SESSION_DATA_PLAIN);
	if (!hasSecureData && !hasPlainData) {
		// Token present but the short-TTL cookie cache has lapsed while the
		// longer-lived token may still be valid. We cannot verify freshness at
		// the edge, so defer to the server gate rather than log the user out.
		return "indeterminate";
	}

	try {
		const cached = await getCookieCache(request, {
			secret: options.secret,
			isSecure: hasSecureData,
		});
		// A verdict was reached: getCookieCache returns a payload only when the
		// signature verifies and the embedded session is unexpired, and returns
		// null when the cache cookie is expired, tampered, or unparseable.
		return cached ? "fresh" : "stale";
	} catch {
		// getCookieCache throws only when the cookie value cannot be decoded at
		// all (e.g. corrupt base64). Treat verification errors as indeterminate
		// so a crypto/parse fault never takes the app down.
		return "indeterminate";
	}
}
