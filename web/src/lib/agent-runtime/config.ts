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

function hasAnyPrReviewerCredential(env: Env): boolean {
	return Boolean(
		env.PR_REVIEWER_APP_ID ||
			env.PR_REVIEWER_PRIVATE_KEY ||
			env.PR_REVIEWER_INSTALLATION_ID,
	);
}

function isPrReviewerConfigured(env: Env): boolean {
	if (env.PR_REVIEWER_ENABLED === "0") return false;
	if (env.PR_REVIEWER_ENABLED === "1") return true;
	return hasAnyPrReviewerCredential(env);
}

/**
 * Gates the continuous-rerun trigger surface (reopened, ready_for_review,
 * synchronize, body/base edits, evidence comments) independently of the
 * managed reviewer as a whole. Reruns have been live in production for
 * weeks, so the default is enabled — only an explicit "0" disables them,
 * falling back to the original opened-only trigger. See
 * docs/pr-review/pr-reviewer.md.
 */
export function isPrReviewerRerunsEnabled(env: Env = process.env): boolean {
	return env.PR_REVIEWER_RERUNS_ENABLED !== "0";
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

	if (isPrReviewerConfigured(env)) {
		requireEnv(
			env,
			"PR_REVIEWER_APP_ID",
			"when PR reviewer is configured",
			errors,
		);
		requireEnv(
			env,
			"PR_REVIEWER_PRIVATE_KEY",
			"when PR reviewer is configured",
			errors,
		);
		requireEnv(
			env,
			"PR_REVIEWER_INSTALLATION_ID",
			"when PR reviewer is configured",
			errors,
		);
		requireEnv(
			env,
			"ANTHROPIC_API_KEY",
			"when PR reviewer is configured",
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
