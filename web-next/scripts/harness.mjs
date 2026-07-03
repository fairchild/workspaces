/*
 * Shared harness for the evidence and perf scripts: serve the production
 * build on a port — in auth-bypass mode over a throwaway database — and
 * launch Chromium (honoring the remote-sandbox executable override).
 * Node-only, no test framework.
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";

export const WEB_NEXT_ROOT = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"..",
);

/** The login the harness servers allowlist and their browsers act as. */
export const HARNESS_LOGIN = "fairchild";

/** Mirrors TEST_AUTH_COOKIE in src/lib/auth/config.ts. */
const TEST_AUTH_COOKIE = "test-auth-login";

/** Playwright cookie that signs a context in under the auth bypass. */
export function testAuthCookie(baseUrl, login = HARNESS_LOGIN) {
	return { name: TEST_AUTH_COOKIE, value: login, url: baseUrl };
}

/**
 * Connects to the harness server's database for direct seeding/wiping.
 * Loads the home page once (signed in) so the app has run its migrations
 * before we touch the file.
 */
export async function connectSeedClient(baseUrl, databaseUrl) {
	const response = await fetch(baseUrl, {
		headers: { cookie: `${TEST_AUTH_COOKIE}=${HARNESS_LOGIN}` },
	});
	if (!response.ok) {
		throw new Error(`schema warm-up failed: HTTP ${response.status}`);
	}
	const { createClient } = await import("@libsql/client");
	return createClient({ url: databaseUrl });
}

/**
 * Auth-bypass server env over a fresh database file (recreated per run) —
 * what evidence/perf runs pass to startProductionServer. Returns the env
 * plus the db url so callers can seed/wipe rows directly.
 */
export function bypassServerEnv(dbDirName) {
	const dbDir = path.join(WEB_NEXT_ROOT, "output", dbDirName);
	rmSync(dbDir, { recursive: true, force: true });
	mkdirSync(dbDir, { recursive: true });
	const databaseUrl = `file:${path.join(dbDir, "sessions.db")}`;
	return {
		env: {
			AUTH_BYPASS: "1",
			ALLOWED_LOGINS: HARNESS_LOGIN,
			SESSIONS_DATABASE_URL: databaseUrl,
		},
		databaseUrl,
	};
}

/** Fails fast when `next build` hasn't produced a servable build. */
export function assertProductionBuild() {
	if (!existsSync(path.join(WEB_NEXT_ROOT, ".next", "BUILD_ID"))) {
		throw new Error("No production build found — run `pnpm build` first.");
	}
}

async function waitForServer(url, timeoutMs = 60_000) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		try {
			const res = await fetch(url);
			if (res.ok) return;
		} catch {
			// Server not accepting connections yet.
		}
		await new Promise((r) => setTimeout(r, 250));
	}
	throw new Error(`Server at ${url} not ready within ${timeoutMs}ms`);
}

/**
 * Starts `next start` on the given port (with optional extra env) and
 * resolves once it serves 200s. Returns { baseUrl, stop } — always call
 * stop() when done.
 */
export async function startProductionServer(port = 3100, env = {}) {
	assertProductionBuild();
	const child = spawn(
		"pnpm",
		["exec", "next", "start", "--port", String(port)],
		{
			cwd: WEB_NEXT_ROOT,
			stdio: ["ignore", "pipe", "pipe"],
			env: { ...process.env, ...env },
		},
	);
	const baseUrl = `http://localhost:${port}`;
	try {
		await waitForServer(baseUrl);
	} catch (error) {
		child.kill("SIGTERM");
		throw error;
	}
	return {
		baseUrl,
		stop: () =>
			new Promise((resolve) => {
				child.once("exit", resolve);
				child.kill("SIGTERM");
			}),
	};
}

/**
 * Launches headless Chromium, using PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH when
 * set (remote sandboxes preinstall a browser and block Playwright's CDN — see
 * docs/development/remote-sessions.md).
 */
export function launchChromium() {
	const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
	return chromium.launch(executablePath ? { executablePath } : {});
}
