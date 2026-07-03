/*
 * Playwright e2e config for web-next: runs specs in tests/e2e against a
 * production build served on port 3100 (webServer builds only when needed).
 */
import { defineConfig, devices } from "@playwright/test";

const BASE_URL = "http://localhost:3100";

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
	reporter: process.env.CI
		? [["list"], ["html", { open: "never" }]]
		: [["list"]],
	use: {
		baseURL: BASE_URL,
		trace: "on-first-retry",
		...(CHROMIUM_EXECUTABLE
			? { launchOptions: { executablePath: CHROMIUM_EXECUTABLE } }
			: {}),
	},
	projects: [
		{
			name: "chromium",
			use: { ...devices["Desktop Chrome"] },
		},
	],
	webServer: {
		command: "pnpm run e2e:server",
		url: BASE_URL,
		reuseExistingServer: !process.env.CI,
		timeout: 180_000,
	},
});
