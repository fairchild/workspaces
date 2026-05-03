import { defineConfig, devices } from "@playwright/test";

const BASE_URL = process.env.PLAYWRIGHT_BASE_URL ?? "http://localhost:3000";
const SKIP_WEB_SERVER = process.env.PLAYWRIGHT_SKIP_WEB_SERVER === "1";
const E2E_DATABASE_URL =
	process.env.PLAYWRIGHT_DATABASE_URL ??
	(process.env.CI ? "file:data/e2e-auth.db" : process.env.TURSO_DATABASE_URL);

// Vercel Deployment Protection: preview URLs redirect to vercel.com/login
// unless callers supply the Protection Bypass for Automation secret. When
// present, send it on every request so validators see the real app.
const BYPASS_SECRET = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;
const extraHTTPHeaders = BYPASS_SECRET
	? {
			"x-vercel-protection-bypass": BYPASS_SECRET,
			"x-vercel-set-bypass-cookie": "true",
		}
	: undefined;

export default defineConfig({
	testDir: "./e2e",
	fullyParallel: true,
	forbidOnly: !!process.env.CI,
	retries: process.env.CI ? 2 : 0,
	workers: process.env.CI ? 1 : undefined,
	reporter: "html",
	use: {
		baseURL: BASE_URL,
		trace: "on-first-retry",
		extraHTTPHeaders,
	},
	projects: [
		{
			name: "fast",
			testMatch: "fast/**",
			use: { ...devices["Desktop Chrome"] },
		},
		{
			name: "full",
			testMatch: "full/**",
			use: { ...devices["Desktop Chrome"] },
		},
		{
			name: "demo",
			testMatch: "demo/**",
			use: {
				...devices["Desktop Chrome"],
				video: "on",
				viewport: { width: 1280, height: 800 },
			},
		},
		{
			name: "qa-explore",
			testMatch: "explore/**/*.spec.ts",
			use: {
				...devices["Desktop Chrome"],
				video: "on",
				trace: "on",
				viewport: { width: 1440, height: 900 },
			},
		},
	],
	globalSetup: "./e2e/seed.ts",
	globalTeardown: "./e2e/teardown.ts",
	webServer: SKIP_WEB_SERVER
		? undefined
		: {
				command: process.env.CI ? "pnpm start" : "pnpm dev",
				url: BASE_URL,
				reuseExistingServer: !process.env.CI,
				timeout: 120_000,
				env: {
					DEV_BYPASS_AUTH: "1",
					MOCK_AGENT: "1",
					...(E2E_DATABASE_URL ? { TURSO_DATABASE_URL: E2E_DATABASE_URL } : {}),
				},
			},
});
