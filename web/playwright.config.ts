import { defineConfig } from "@playwright/test";

export default defineConfig({
	testDir: "./e2e",
	outputDir: "./e2e/results",
	timeout: 30_000,
	retries: 0,
	use: {
		baseURL: "http://localhost:3003",
		screenshot: "on",
		video: "retain-on-failure",
		trace: "retain-on-failure",
	},
	projects: [
		{
			name: "chromium",
			use: { browserName: "chromium" },
		},
	],
	webServer: {
		command: "pnpm dev --port 3003",
		port: 3003,
		reuseExistingServer: true,
		timeout: 30_000,
	},
});
