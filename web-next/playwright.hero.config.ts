/*
 * Playwright config for the video-recorded hero-flow demo (tests/demo/).
 * Unlike the hermetic e2e suite, this expects an already-running server on
 * HERO_DEMO_PORT (default 3200) wired to the REAL vercel compute provider —
 * the run costs sandbox + model money and opens a real draft PR on GitHub.
 * Video is always on; artifacts land under output/hero-demo/.
 */
import { defineConfig, devices } from "@playwright/test";
import { E2E_LOGIN, signedInAs } from "./playwright.config";

const PORT = Number(process.env.HERO_DEMO_PORT ?? 3200);

export default defineConfig({
	testDir: "./tests/demo",
	timeout: 25 * 60_000,
	retries: 0,
	workers: 1,
	reporter: [["list"]],
	outputDir: "output/hero-demo/test-results",
	use: {
		...devices["Desktop Chrome"],
		viewport: { width: 1280, height: 720 },
		baseURL: `http://localhost:${PORT}`,
		storageState: signedInAs(E2E_LOGIN),
		video: { mode: "on", size: { width: 1280, height: 720 } },
		trace: "off",
	},
});
