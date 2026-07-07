/*
 * Playwright e2e config for web-next. Default (unset VALIDATE_TARGET_URL):
 * runs specs in tests/e2e against a production build served on port 3100
 * (webServer builds only when needed), auth-bypass mode (see e2e:server),
 * every test starting signed in as the allowlisted user via the seeded test
 * cookie — byte-identical to before #817. Deployed seam (VALIDATE_TARGET_URL
 * set — scripts/validate.mjs's e2eDeployedSafeStage is the only caller):
 * points baseURL at a real deployment, swaps the storage state for a real
 * Better Auth session cookie (WEB_NEXT_VALIDATION_SESSION, the pre-minted
 * validation identity — see docs/decisions/web-next-validation-identity.md),
 * carries the Vercel protection-bypass header for SSO-walled previews, turns
 * on screenshots, and redirects reporter/output under output/validate/. Spec
 * curation for that seam is per-test: only `@deployed-safe`-tagged specs are
 * read-mostly enough to run against a real environment (validate.mjs greps
 * for the tag; nothing here filters by tag, so `pnpm test:e2e` locally still
 * runs everything).
 */
import path from "node:path";
import { defineConfig, devices } from "@playwright/test";

// E2E_PORT lets concurrent checkouts (sibling worktrees) run their own e2e
// servers without colliding on one port — parity with the perf runner's
// PERF_PORT. Default stays 3100 (CI and the common case).
const PORT = Number(process.env.E2E_PORT ?? 3100);
const BASE_URL = `http://localhost:${PORT}`;

// Playwright transpiles this config to CJS regardless of package.json's
// module type, so `import.meta.url` (used elsewhere in this repo's ESM
// scripts) isn't available here — __dirname is what actually works.
const WEB_NEXT_ROOT = __dirname;

/** Must match ALLOWED_LOGINS in the e2e:server script. */
export const E2E_LOGIN = "fairchild";

export const signedInAs = (login: string) => ({
	cookies: [
		{
			name: "test-auth-login",
			value: login,
			domain: "localhost",
			path: "/",
			expires: -1,
			httpOnly: false,
			secure: false,
			sameSite: "Lax" as const,
		},
	],
	origins: [],
});

/**
 * Better Auth's session-token cookie is `__Secure-` prefixed over https (see
 * src/lib/auth/session-cookie.ts's SESSION_TOKEN_COOKIES) — a deployed
 * target is always https, so this always picks the secure name in practice.
 */
function validationSessionStorageState(baseUrl: string, sessionToken: string) {
	const url = new URL(baseUrl);
	const secure = url.protocol === "https:";
	return {
		cookies: [
			{
				name: secure ? "__Secure-better-auth.session_token" : "better-auth.session_token",
				value: sessionToken,
				domain: url.hostname,
				path: "/",
				expires: -1,
				httpOnly: true,
				secure,
				sameSite: "Lax" as const,
			},
		],
		origins: [],
	};
}

/** Resolves the deployed-target seam, or undefined for the untouched local default. */
function resolveDeployedTarget(): { baseUrl: string; sessionToken: string } | undefined {
	const targetUrl = process.env.VALIDATE_TARGET_URL;
	if (!targetUrl) return undefined;
	const sessionToken = process.env.WEB_NEXT_VALIDATION_SESSION;
	if (!sessionToken) {
		// The e2eDeployedSafeStage gates on this before it ever spawns Playwright
		// — reaching here without it means the config was invoked some other
		// way, and failing loudly beats silently running unauthenticated.
		throw new Error(
			"VALIDATE_TARGET_URL is set but WEB_NEXT_VALIDATION_SESSION is not — set both, or neither.",
		);
	}
	return { baseUrl: targetUrl.replace(/\/$/, ""), sessionToken };
}

const deployedTarget = resolveDeployedTarget();
const isDeployed = !!deployedTarget;
const envName = process.env.VALIDATE_ENV_NAME ?? "deployed";
const bypassSecret = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;

// Remote sandboxes (claude.ai sessions) preinstall a Chromium whose revision
// may trail the @playwright/test pin, and their proxy blocks Playwright's CDN,
// so the pinned browser can't be downloaded. Point this at the preinstalled
// binary (e.g. /opt/pw-browsers/chromium) to run e2e there. Unset everywhere
// else — CI and dev machines use the pinned download.
// See docs/development/remote-sessions.md.
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;

export default defineConfig({
	testDir: "./tests/e2e",
	fullyParallel: true,
	forbidOnly: !!process.env.CI,
	retries: process.env.CI ? 2 : 0,
	reporter: isDeployed
		? [
				["list"],
				[
					"json",
					{
						outputFile:
							process.env.VALIDATE_E2E_JSON_OUTPUT ??
							path.join(WEB_NEXT_ROOT, "output", "validate", envName, "e2e-results.json"),
					},
				],
			]
		: process.env.CI
			? [["list"], ["html", { open: "never" }]]
			: [["list"]],
	use: {
		baseURL: deployedTarget ? deployedTarget.baseUrl : BASE_URL,
		storageState: deployedTarget
			? validationSessionStorageState(deployedTarget.baseUrl, deployedTarget.sessionToken)
			: signedInAs(E2E_LOGIN),
		// Deployed runs turn trace off (screenshots are the deployed evidence
		// instead): Playwright traces capture request/response headers, which
		// would embed the validation session cookie and the bypass header in an
		// artifact — a credential-in-report risk the local path doesn't have
		// (its cookie is a throwaway test-bypass value, not a real session).
		trace: isDeployed ? "off" : "on-first-retry",
		...(isDeployed
			? {
					screenshot: "on" as const,
					...(bypassSecret ? { extraHTTPHeaders: { "x-vercel-protection-bypass": bypassSecret } } : {}),
				}
			: {}),
		...(CHROMIUM_EXECUTABLE
			? { launchOptions: { executablePath: CHROMIUM_EXECUTABLE } }
			: {}),
	},
	projects: [
		{
			name: "chromium",
			use: { ...devices["Desktop Chrome"] },
			// sessions.spec owns the sessions table (wipes + counts rows), so
			// specs that create sessions of their own run in a later project.
			testIgnore: /terminal\.spec\.ts/,
		},
		{
			name: "terminal",
			use: { ...devices["Desktop Chrome"] },
			testMatch: /terminal\.spec\.ts/,
			dependencies: ["chromium"],
		},
	],
	...(isDeployed
		? { outputDir: path.join(WEB_NEXT_ROOT, "output", "validate", envName, "test-results") }
		: {
				webServer: {
					command: "pnpm run e2e:server",
					url: BASE_URL,
					reuseExistingServer: !process.env.CI,
					timeout: 180_000,
				},
			}),
});
