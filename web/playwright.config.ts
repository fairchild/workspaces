import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
	testDir: "./e2e",
	fullyParallel: true,
	forbidOnly: !!process.env.CI,
	retries: process.env.CI ? 2 : 0,
	workers: process.env.CI ? 1 : undefined,
	reporter: "html",
	use: {
		baseURL: "http://localhost:3000",
		trace: "on-first-retry",
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
	],
	globalSetup: "./e2e/seed.ts",
	globalTeardown: "./e2e/teardown.ts",
	webServer: {
		command: process.env.CI ? "pnpm start" : "pnpm dev",
		url: "http://localhost:3000",
		reuseExistingServer: !process.env.CI,
		timeout: 120_000,
		env: {
			DEV_BYPASS_AUTH: "1",
		},
	},
});
