/*
 * The per-sandbox HMAC path token gating the in-sandbox ttyd endpoint (#752).
 * ttyd serves its WebSocket under `--base-path /<token>`; the token is an HMAC
 * of the sandbox VM's unique session id under a server-side secret, so knowing
 * (or guessing) a sandbox name reveals nothing connectable. Stateless — both
 * the ttyd launch and the redeem route recompute it — and scoped to one VM:
 * a new VM session under the same sandbox name derives a different token.
 * Ported from web/'s ttydPathToken; secret resolution is identical
 * (TTYD_TOKEN_SECRET, falling back to BETTER_AUTH_SECRET — the #857 lesson).
 */
import crypto from "node:crypto";

type Env = Record<string, string | undefined>;

const DEV_FALLBACK_SECRET = "web-next-dev-terminal-secret-not-for-prod";

/** The HMAC secret; a stable throwaway outside production, required inside. */
export function terminalTokenSecret(env: Env = process.env): string {
	const secret = env.TTYD_TOKEN_SECRET ?? env.BETTER_AUTH_SECRET;
	if (secret) return secret;
	if (env.NODE_ENV !== "production") return DEV_FALLBACK_SECRET;
	throw new Error(
		"TTYD_TOKEN_SECRET or BETTER_AUTH_SECRET is required for terminal access in production",
	);
}

/** 24 hex chars of HMAC-SHA256(secret, sandbox VM session id). */
export function terminalPathToken(
	sandboxSessionId: string,
	env: Env = process.env,
): string {
	return crypto
		.createHmac("sha256", terminalTokenSecret(env))
		.update(sandboxSessionId)
		.digest("hex")
		.slice(0, 24);
}
