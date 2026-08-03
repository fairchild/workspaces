const DEV_ALLOWED_AGENT_LOGINS = "fairchild";
const NON_PRODUCTION_BETTER_AUTH_SECRET =
	"workspaces-non-production-better-auth-secret";
const TERMINAL_ANTHROPIC_OPT_IN = "1";

type Env = Partial<NodeJS.ProcessEnv>;

function isProduction(env: Env = process.env): boolean {
	if (env.VERCEL_ENV === "preview" || env.VERCEL_ENV === "development") {
		return false;
	}
	return env.NODE_ENV === "production";
}

function splitCsv(value: string | undefined): string[] {
	return (value ?? "")
		.split(",")
		.map((s) => s.trim())
		.filter(Boolean);
}

function hasVercelCredentials(env: Env): boolean {
	return Boolean(
		env.VERCEL_OIDC_TOKEN ||
			(env.VERCEL_TOKEN && env.VERCEL_TEAM_ID && env.VERCEL_PROJECT_ID),
	);
}

function requireEnv(
	env: Env,
	name: string,
	description: string,
	errors: string[],
): void {
	if (!env[name]) errors.push(`${name} is required ${description}`);
}

export function parseAllowedAgentLogins(env: Env = process.env): Set<string> {
	const configured = env.ALLOWED_AGENT_LOGINS;
	const raw =
		configured !== undefined || isProduction(env)
			? configured
			: DEV_ALLOWED_AGENT_LOGINS;
	return new Set(splitCsv(raw));
}

/** GitHub logins allowed to trigger agent compute sessions. */
export const ALLOWED_AGENT_LOGINS = parseAllowedAgentLogins();

export function shouldExposeAnthropicKeyToTerminal(
	env: Env = process.env,
): boolean {
	return env.TERMINAL_ANTHROPIC_API_KEY === TERMINAL_ANTHROPIC_OPT_IN;
}

export function validateProductionAuthConfig(env: Env = process.env): void {
	if (!isProduction(env)) return;
	const errors: string[] = [];
	requireEnv(env, "BETTER_AUTH_SECRET", "for production auth sessions", errors);
	if (errors.length > 0) {
		throw new Error(`Invalid production auth config: ${errors.join("; ")}`);
	}
}

export function resolveBetterAuthSecret(env: Env = process.env): string {
	if (env.BETTER_AUTH_SECRET) return env.BETTER_AUTH_SECRET;
	if (!isProduction(env)) return NON_PRODUCTION_BETTER_AUTH_SECRET;
	throw new Error(
		"Invalid production auth config: BETTER_AUTH_SECRET is required for production auth sessions",
	);
}

export function validateProductionAgentRuntimeConfig(
	env: Env = process.env,
): void {
	if (!isProduction(env)) return;

	const errors: string[] = [];
	if (parseAllowedAgentLogins(env).size === 0) {
		errors.push(
			"ALLOWED_AGENT_LOGINS is required and must contain at least one login",
		);
	}
	requireEnv(
		env,
		"BETTER_AUTH_SECRET",
		"for authenticated app sessions",
		errors,
	);
	// Terminal URL signing uses TTYD_TOKEN_SECRET and falls back to
	// BETTER_AUTH_SECRET (resolveTtydTokenSecret in vercel-sandbox.ts). Either
	// secret satisfies the runtime, so accept either here rather than demanding
	// a dedicated TTYD_TOKEN_SECRET the signer never requires.
	if (!env.TTYD_TOKEN_SECRET && !env.BETTER_AUTH_SECRET) {
		errors.push(
			"TTYD_TOKEN_SECRET or BETTER_AUTH_SECRET is required for terminal URL signing in production",
		);
	}

	if (!hasVercelCredentials(env)) {
		errors.push(
			"Vercel Sandbox credentials are required (VERCEL_OIDC_TOKEN or VERCEL_TOKEN + VERCEL_TEAM_ID + VERCEL_PROJECT_ID)",
		);
	}

	const defaultProvider = env.COMPUTE_PROVIDER ?? "vercel-sandbox";
	if (
		defaultProvider === "vercel-sandbox" ||
		defaultProvider === "managed-agents"
	) {
		requireEnv(
			env,
			"ANTHROPIC_API_KEY",
			`for ${defaultProvider} agent sessions`,
			errors,
		);
	}

	if (errors.length > 0) {
		throw new Error(
			`Invalid production agent runtime config:\n- ${errors.join("\n- ")}`,
		);
	}
}

/** Agent name to use when no @mention is provided. Null disables default routing. */
export const DEFAULT_AGENT: string | null = process.env.DEFAULT_AGENT ?? null;
