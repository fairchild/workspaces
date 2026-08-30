/*
 * Auth environment contract, pure and edge-safe (no imports): the login
 * allowlist (single-user product — one GitHub login, maybe a bot), the
 * real-OAuth/test-bypass mode switch, and secret resolution. Everything
 * here reads env only, so middleware can share it with server components.
 */

type Env = Record<string, string | undefined>;

/**
 * Cookie carrying the acting login under the test bypass (see
 * authBypassEnabled). Read by middleware and getAuthState only when the
 * bypass is active; in real-auth mode it is inert data.
 */
export const TEST_AUTH_COOKIE = "test-auth-login";

/**
 * Cookie carrying the bearer token for owner-local serving mode. This is not
 * the test bypass: it is minted locally, persisted under the data dir, and only
 * honored when WEB_NEXT_LOCAL_MODE=1.
 */
export const LOCAL_AUTH_COOKIE = "web-next-local-session";

/** GitHub logins allowed in (`ALLOWED_LOGINS`, csv, case-insensitive). */
export function parseAllowedLogins(env: Env = process.env): Set<string> {
	return new Set(
		(env.ALLOWED_LOGINS ?? "")
			.split(",")
			.map((login) => login.trim().toLowerCase())
			.filter((login) => login.length > 0),
	);
}

export function isLoginAllowed(
	login: string | null | undefined,
	env: Env = process.env,
): boolean {
	if (!login) return false;
	return parseAllowedLogins(env).has(login.trim().toLowerCase());
}

/** True once a GitHub OAuth app is configured — the "this is real" signal. */
export function realAuthConfigured(env: Env = process.env): boolean {
	return Boolean(env.GITHUB_OAUTH_CLIENT_ID);
}

/** Any GitHub OAuth var means the server is trying to use the real OAuth door. */
export function oauthEnvConfigured(env: Env = process.env): boolean {
	return Boolean(env.GITHUB_OAUTH_CLIENT_ID || env.GITHUB_OAUTH_CLIENT_SECRET);
}

/** First-class local serving mode: loopback + locally minted bearer token. */
export function localModeEnabled(env: Env = process.env): boolean {
	return env.WEB_NEXT_LOCAL_MODE === "1";
}

export function resolveLocalLogin(env: Env = process.env): string {
	const login = env.WEB_NEXT_LOCAL_LOGIN?.trim();
	return login && login.length > 0 ? login.toLowerCase() : "fairchild";
}

export function assertAuthModeConfig(env: Env = process.env): void {
	if (!localModeEnabled(env)) return;
	if (env.AUTH_BYPASS === "1") {
		throw new Error("WEB_NEXT_LOCAL_MODE cannot be combined with AUTH_BYPASS=1");
	}
	if (oauthEnvConfigured(env)) {
		throw new Error(
			"WEB_NEXT_LOCAL_MODE cannot be combined with GitHub OAuth environment variables",
		);
	}
}

/**
 * Test/dev auth bypass: cookie-driven identity instead of GitHub OAuth, so
 * e2e, evidence, and perf runs work headlessly. Triple-locked:
 *
 * 1. `AUTH_BYPASS=1` must be set explicitly (never set it in production).
 * 2. It is inert whenever a real OAuth app is configured — production sets
 *    GITHUB_OAUTH_CLIENT_ID, so even a leaked AUTH_BYPASS=1 cannot open it.
 * 3. It is inert on Vercel runtime (`VERCEL` is present there), so a deploy
 *    that accidentally carries AUTH_BYPASS=1 but omits OAuth config still
 *    refuses the unsigned test cookie.
 *
 * When active, the absence of TEST_AUTH_COOKIE is still "signed out": the
 * unauth redirect and the allowlist rejection stay testable per request.
 */
export function authBypassEnabled(env: Env = process.env): boolean {
	return (
		env.AUTH_BYPASS === "1" &&
		!localModeEnabled(env) &&
		!realAuthConfigured(env) &&
		!env.VERCEL
	);
}

const encoder = new TextEncoder();

/**
 * Edge-safe constant-time string comparison. It keeps the loop count tied to
 * the longest encoded input and folds the length mismatch into the result, so
 * callers do not branch early on unequal lengths.
 */
export function constantTimeEqual(left: string, right: string): boolean {
	const a = encoder.encode(left);
	const b = encoder.encode(right);
	let diff = a.length ^ b.length;
	const length = Math.max(a.length, b.length);
	for (let index = 0; index < length; index += 1) {
		diff |= (a[index] ?? 0) ^ (b[index] ?? 0);
	}
	return diff === 0;
}

export function localSessionCookieValid(
	cookieValue: string | null | undefined,
	env: Env = process.env,
): boolean {
	if (!localModeEnabled(env) || !cookieValue || !env.WEB_NEXT_LOCAL_TOKEN) {
		return false;
	}
	return constantTimeEqual(cookieValue, env.WEB_NEXT_LOCAL_TOKEN);
}

function hostHeaderHasValidPortToken(hostHeader: string): boolean {
	if (hostHeader.startsWith("[")) {
		const match = hostHeader.match(/^\[[^\]]+\](?::([0-9]+))?$/);
		return match !== null;
	}
	const parts = hostHeader.split(":");
	if (parts.length === 1) return true;
	return parts.length === 2 && /^[0-9]+$/.test(parts[1] ?? "");
}

export function loopbackHostOrigin(hostHeader: string | null): string | null {
	if (!hostHeader) return null;
	const host = hostHeader.trim().toLowerCase();
	if (!hostHeaderHasValidPortToken(host)) return null;
	try {
		const url = new URL(`http://${host}`);
		if (url.pathname !== "/" || url.search !== "" || url.hash !== "") return null;
		if (!["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)) return null;
		return url.origin;
	} catch {
		return null;
	}
}

export function isLoopbackHostHeader(hostHeader: string | null): boolean {
	return loopbackHostOrigin(hostHeader) !== null;
}

/**
 * Extra exact-match origins allowed to reach owner-local serving through a
 * trusted reverse proxy (`tailscale serve` fronting the loopback bind). Set
 * `WEB_NEXT_EXTRA_LOCAL_ORIGINS` to comma-separated full origins (e.g.
 * `https://mac.tailxxxx.ts.net`); inert unless set. Exact match only — never
 * a wildcard — per docs/decisions/mobile-tailnet-design.md.
 */
export function parseExtraLocalOrigins(env: Env = process.env): Set<string> {
	return new Set(
		(env.WEB_NEXT_EXTRA_LOCAL_ORIGINS ?? "")
			.split(",")
			.map((origin) => origin.trim().toLowerCase().replace(/\/+$/, ""))
			.filter((origin) => origin.length > 0),
	);
}

/**
 * The request's local-serving origin: the loopback origin as always, or an
 * allowlisted extra origin reconstructed from Host + X-Forwarded-Proto. The
 * scheme participates in the exact match, so a forged proto header can only
 * produce an origin that fails the allowlist — and the token cookie, not
 * this gate, is what authorizes either way.
 */
export function localRequestOrigin(
	hostHeader: string | null,
	forwardedProto: string | null,
	env: Env = process.env,
): string | null {
	const loopback = loopbackHostOrigin(hostHeader);
	if (loopback) return loopback;
	if (!hostHeader) return null;
	const extras = parseExtraLocalOrigins(env);
	if (extras.size === 0) return null;
	const host = hostHeader.trim().toLowerCase();
	if (!hostHeaderHasValidPortToken(host)) return null;
	const scheme =
		forwardedProto?.trim().toLowerCase() === "https" ? "https" : "http";
	try {
		const url = new URL(`${scheme}://${host}`);
		if (url.pathname !== "/" || url.search !== "" || url.hash !== "") return null;
		return extras.has(url.origin) ? url.origin : null;
	} catch {
		return null;
	}
}

/**
 * Better Auth signing secret. Required once real OAuth is configured (a
 * guessable secret would forge session cookies); test/bypass modes get a
 * stable throwaway so local servers boot without ceremony.
 */
export function resolveAuthSecret(env: Env = process.env): string {
	if (env.BETTER_AUTH_SECRET) return env.BETTER_AUTH_SECRET;
	if (realAuthConfigured(env)) {
		throw new Error(
			"BETTER_AUTH_SECRET is required when GitHub OAuth is configured",
		);
	}
	return "web-next-insecure-test-secret";
}
