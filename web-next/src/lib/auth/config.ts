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
	return env.AUTH_BYPASS === "1" && !realAuthConfigured(env) && !env.VERCEL;
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
