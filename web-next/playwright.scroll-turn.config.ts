/*
 * Playwright config for the filmed #1015 turn-scroll proof. It starts the
 * hermetic mock-provider app on an isolated port, records one 1280x720 video,
 * and keeps the artifact separate from the normal E2E suite.
 */
import { defineConfig, devices } from "@playwright/test";
import { E2E_LOGIN, signedInAs } from "./playwright.config";

const PORT = Number(process.env.SCROLL_TURN_PORT ?? 3218);

export default defineConfig({
	testDir: "./tests/demo",
	testMatch: /scroll-turn\.spec\.ts/,
	timeout: 60_000,
	retries: 0,
	workers: 1,
	reporter: [["list"]],
	outputDir: "output/scroll-turn/test-results",
	use: {
		...devices["Desktop Chrome"],
		viewport: { width: 1280, height: 720 },
		baseURL: `http://localhost:${PORT}`,
		storageState: signedInAs(E2E_LOGIN),
		video: { mode: "on", size: { width: 1280, height: 720 } },
		trace: "off",
	},
	webServer: {
		command: `WEB_NEXT_COMPUTE_PROVIDER=mock E2E_PORT=${PORT} pnpm run e2e:server`,
		url: `http://localhost:${PORT}`,
		reuseExistingServer: false,
		timeout: 180_000,
	},
});
