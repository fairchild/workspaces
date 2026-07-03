/*
 * Evidence capture: screenshots of / and /spike in both color schemes
 * (light + dark), with /spike captured after a full streamed mock turn.
 * Output goes to output/evidence/ (gitignored); CI uploads it as an
 * artifact — the sanctioned publish path per docs/development/remote-sessions.md.
 * The app is dark-only today, so the light captures record current reality.
 */
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

async function main() {
	mkdirSync(OUTPUT_DIR, { recursive: true });
	const server = await startProductionServer(PORT);
	const browser = await launchChromium();
	try {
		for (const colorScheme of ["light", "dark"]) {
			const context = await browser.newContext({
				baseURL: server.baseUrl,
				colorScheme,
				viewport: { width: 1280, height: 800 },
				deviceScaleFactor: 2,
			});
			const page = await context.newPage();
			const shot = (name) => path.join(OUTPUT_DIR, `${name}-${colorScheme}.png`);
			await captureHome(page, shot("home"));
			await captureSpikeAfterTurn(page, shot("spike"));
			await context.close();
			console.log(`captured home + spike (${colorScheme})`);
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
