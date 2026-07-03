/*
 * Evidence capture: screenshots of /, /spike (after a full streamed mock
 * turn), and the Folio session demo (/sessions/demo) in both themes —
 * plus the refine-folio prototype itself, captured beside the demo for
 * pixel comparison. Output goes to output/evidence/ (gitignored); CI
 * uploads it as an artifact — the sanctioned publish path per
 * docs/development/remote-sessions.md.
 */
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import path from "node:path";
import {
	launchChromium,
	startProductionServer,
	WEB_NEXT_ROOT,
} from "./harness.mjs";

const OUTPUT_DIR = path.join(WEB_NEXT_ROOT, "output", "evidence");
const PORT = Number(process.env.EVIDENCE_PORT ?? 3100);
const TURN_TIMEOUT_MS = 20_000;
// Entry animations (rise/settle) finish ~1.1s after load; let them land.
const ANIMATION_SETTLE_MS = 1500;
const PROTOTYPE_PATH = path.resolve(
	WEB_NEXT_ROOT,
	"../prototypes/web-session-redesign/refine-folio.html",
);

async function captureHome(page, file) {
	await page.goto("/", { waitUntil: "networkidle" });
	await page.screenshot({ path: file });
}

async function captureSpikeAfterTurn(page, file) {
	await page.goto("/spike", { waitUntil: "networkidle" });
	await page.fill(
		'input[placeholder="Ask the agent to fix something…"]',
		"Fix the failing session test",
	);
	await page.click('button[type="submit"]');
	// The turn is done when the closing prose streamed in and the compose
	// re-enabled (stream finished, not just started its last paragraph).
	await page.waitForFunction(
		() =>
			document
				.querySelector('[data-message-role="assistant"]')
				?.textContent?.includes("All four tests pass") &&
			!document.querySelector('button[type="submit"]')?.disabled,
		undefined,
		{ timeout: TURN_TIMEOUT_MS },
	);
	// The transcript scrolls inside the page; show the end of the turn.
	await page.evaluate(() => {
		const transcript = document.querySelector("main > div.overflow-y-auto");
		if (transcript) transcript.scrollTop = transcript.scrollHeight;
	});
	await page.screenshot({ path: file });
}

async function captureSessionsDemo(page, file) {
	await page.goto("/sessions/demo", { waitUntil: "networkidle" });
	await page.waitForTimeout(ANIMATION_SETTLE_MS);
	await page.screenshot({ path: file });
}

// --- prototype capture -------------------------------------------------------
// The prototype loads Newsreader/IBM Plex Mono from Google Fonts; headless
// Chromium in sandboxes has no direct egress, so font requests are fulfilled
// through curl (which honors the agent proxy + CA bundle).

const fontCache = new Map();

function fetchFontResource(url, userAgent) {
	if (!fontCache.has(url)) {
		fontCache.set(
			url,
			execFileSync(
				"curl",
				["-sS", "--fail", "--max-time", "30", "-A", userAgent, url],
				{ maxBuffer: 64 * 1024 * 1024 },
			),
		);
	}
	return fontCache.get(url);
}

export async function routeFontsThroughCurl(context) {
	await context.route(
		(url) =>
			url.hostname === "fonts.googleapis.com" ||
			url.hostname === "fonts.gstatic.com",
		async (route) => {
			const request = route.request();
			try {
				const body = fetchFontResource(
					request.url(),
					request.headers()["user-agent"] ?? "Mozilla/5.0",
				);
				await route.fulfill({
					body,
					contentType: request.url().includes("googleapis")
						? "text/css"
						: "font/woff2",
				});
			} catch {
				await route.abort();
			}
		},
	);
}

async function capturePrototype(page, theme, file) {
	await page.goto(`file://${PROTOTYPE_PATH}#${theme}`, {
		waitUntil: "networkidle",
	});
	await page.evaluate(() => document.fonts.ready);
	await page.waitForTimeout(ANIMATION_SETTLE_MS);
	await page.screenshot({ path: file });
}

async function main() {
	mkdirSync(OUTPUT_DIR, { recursive: true });
	const server = await startProductionServer(PORT);
	const browser = await launchChromium();
	try {
		for (const colorScheme of ["light", "dark"]) {
			// colorScheme emulation drives the app theme (system preference is
			// the default resolution); the prototype is forced via its hash.
			const context = await browser.newContext({
				baseURL: server.baseUrl,
				colorScheme,
				viewport: { width: 1280, height: 800 },
				deviceScaleFactor: 2,
			});
			await routeFontsThroughCurl(context);
			const page = await context.newPage();
			const shot = (name) => path.join(OUTPUT_DIR, `${name}-${colorScheme}.png`);
			await captureHome(page, shot("home"));
			await captureSpikeAfterTurn(page, shot("spike"));
			await captureSessionsDemo(page, shot("sessions-demo"));
			await capturePrototype(page, colorScheme, shot("prototype-folio"));
			await context.close();
			console.log(
				`captured home + spike + sessions-demo + prototype (${colorScheme})`,
			);
		}
	} finally {
		await browser.close();
		await server.stop();
	}
	console.log(`evidence written to ${OUTPUT_DIR}`);
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
