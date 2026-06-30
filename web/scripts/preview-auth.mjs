#!/usr/bin/env node
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium } from "@playwright/test";

const DEFAULT_QA_HOST = "qa.spaces-preview.cloudcompute.com";

function usage() {
	return [
		"usage: node scripts/preview-auth.mjs (--pr <number> | --url <url>) [--host <host>]",
		"",
		"Creates a local authenticated Playwright storage state for a Vercel preview.",
	].join("\n");
}

function parseArgs(argv) {
	let host = process.env.PREVIEW_QA_ALIAS_HOST ?? DEFAULT_QA_HOST;
	let pr = "";
	let url = "";
	for (let i = 0; i < argv.length; i += 1) {
		const arg = argv[i];
		if (arg === "--pr") {
			pr = argv[++i] ?? "";
		} else if (arg === "--url") {
			url = argv[++i] ?? "";
		} else if (arg === "--host") {
			host = argv[++i] ?? "";
		} else if (arg === "--help" || arg === "-h") {
			console.log(usage());
			process.exit(0);
		} else {
			throw new Error(`unknown argument: ${arg}`);
		}
	}

	if (url && pr) throw new Error("pass either --pr or --url, not both");
	if (pr) {
		if (!/^\d+$/.test(pr)) throw new Error("--pr must be a PR number");
		if (!host) throw new Error("missing --host");
		return new URL(`https://${host}`);
	}
	if (url) return new URL(url);
	throw new Error("missing --pr or --url");
}

function safeHost(host) {
	return host.replace(/[^A-Za-z0-9_.-]/g, "_");
}

function isDashboardUrl(url, origin) {
	try {
		const current = new URL(url);
		return (
			current.origin === origin && current.pathname.startsWith("/dashboard")
		);
	} catch {
		return false;
	}
}

async function clickGitHubSignIn(page) {
	const button = page.getByRole("button", { name: /Continue with GitHub/i });
	if ((await button.count()) === 0) return false;
	await button.click();
	return true;
}

const target = parseArgs(process.argv.slice(2));
const origin = target.origin;
const host = safeHost(target.host);
const authDir = path.join(process.cwd(), ".auth");
const outputDir = path.join(process.cwd(), "output", "preview-qa");
const userDataDir = path.join(authDir, "preview-profile");
const storageStatePath = path.join(authDir, `preview-${host}.json`);
const screenshotPath = path.join(
	outputDir,
	`${host}-authenticated-dashboard.png`,
);

await mkdir(authDir, { recursive: true });
await mkdir(outputDir, { recursive: true });

const bypassSecret = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;

if (!bypassSecret) {
	console.warn(
		"VERCEL_AUTOMATION_BYPASS_SECRET is not set; this only works if your browser profile already passes Vercel Deployment Protection.",
	);
}

const context = await chromium.launchPersistentContext(userDataDir, {
	headless: false,
	viewport: { width: 1440, height: 900 },
});

try {
	const page = context.pages()[0] ?? (await context.newPage());
	const dashboardUrl = new URL("/dashboard", origin).toString();

	if (bypassSecret) {
		await context.request
			.get(dashboardUrl, {
				failOnStatusCode: false,
				headers: {
					"x-vercel-protection-bypass": bypassSecret,
					"x-vercel-set-bypass-cookie": "true",
				},
				timeout: 15_000,
			})
			.catch(() => {});
	}

	console.log(`Opening preview dashboard at ${origin}`);
	await page.goto(dashboardUrl, { waitUntil: "domcontentloaded" });

	if (!isDashboardUrl(page.url(), origin)) {
		const clicked = await clickGitHubSignIn(page);
		if (clicked) {
			console.log(
				"Complete the GitHub OAuth flow in the opened browser window. Waiting up to 5 minutes...",
			);
		} else {
			console.log(
				"Waiting for the preview browser to reach /dashboard. Sign in manually if prompted.",
			);
		}
		await page.waitForURL((url) => isDashboardUrl(url.toString(), origin), {
			timeout: 300_000,
			waitUntil: "domcontentloaded",
		});
	}

	await page
		.waitForLoadState("networkidle", { timeout: 15_000 })
		.catch(() => {});

	if (!isDashboardUrl(page.url(), origin)) {
		throw new Error("preview auth did not finish on the dashboard route");
	}

	await context.storageState({ path: storageStatePath });
	await page
		.screenshot({ path: screenshotPath, fullPage: true })
		.catch(() => {});

	console.log(`Saved storage state: ${storageStatePath}`);
	console.log(`Saved dashboard screenshot: ${screenshotPath}`);
} finally {
	await context.close();
}
