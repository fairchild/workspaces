/*
 * Playwright e2e config for web-next: runs specs in tests/e2e against a
 * production build served on port 3100 (webServer builds only when needed).
 * The server runs in auth-bypass mode (see e2e:server) and every test starts
 * signed in as the allowlisted user via the seeded test cookie; auth specs
 * override storageState to exercise signed-out / wrong-user requests.
 */
import { defineConfig, devices } from "@playwright/test";

// E2E_PORT lets concurrent checkouts (sibling worktrees) run their own e2e
// servers without colliding on one port — parity with the perf runner's
// PERF_PORT. Default stays 3100 (CI and the common case).
const PORT = Number(process.env.E2E_PORT ?? 3100);
const BASE_URL = `http://localhost:${PORT}`;

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
		storageState: signedInAs(E2E_LOGIN),
		trace: "on-first-retry",
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
	webServer: {
		command: "pnpm run e2e:server",
		url: BASE_URL,
		reuseExistingServer: !process.env.CI,
		timeout: 180_000,
	},
});
