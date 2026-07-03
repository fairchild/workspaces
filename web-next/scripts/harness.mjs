/*
 * Shared harness for the evidence and perf scripts: serve the production
 * build on a port and launch Chromium (honoring the remote-sandbox
 * executable override). Node-only, no test framework.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";

export const WEB_NEXT_ROOT = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"..",
);

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
 * Starts `next start` on the given port and resolves once it serves 200s.
 * Returns { baseUrl, stop } — always call stop() when done.
 */
export async function startProductionServer(port = 3100) {
	assertProductionBuild();
	const child = spawn(
		"pnpm",
		["exec", "next", "start", "--port", String(port)],
		{ cwd: WEB_NEXT_ROOT, stdio: ["ignore", "pipe", "pipe"] },
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
