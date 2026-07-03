/*
 * Evidence capture, light + dark: the sessions home (empty and populated),
 * an empty session reached through the real new-session flow, /spike after
 * a full streamed mock turn, the Folio session demo, and the refine-folio
 * prototype beside it for pixel comparison. Runs against a production
 * build in auth-bypass mode over a throwaway database. Output goes to
 * output/evidence/ (gitignored); CI uploads it as an artifact — the
 * sanctioned publish path per docs/development/remote-sessions.md.
 */
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import path from "node:path";
import {
	bypassServerEnv,
	connectSeedClient,
	launchChromium,
	startProductionServer,
	testAuthCookie,
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

// --- database state ----------------------------------------------------------
// Each theme pass replays the same story on clean tables: empty home →
// UI-created session → a seeded, lived-in home.

async function wipeRows(db) {
	for (const table of ["session_events", "sessions", "repos"]) {
		await db.execute(`DELETE FROM ${table}`);
	}
}

/** Two titled sessions with staggered recency behind the UI-created one. */
async function seedPopulatedHome(db) {
	const hoursAgo = (h) => new Date(Date.now() - h * 3_600_000).toISOString();
	await db.execute({
		sql: "INSERT OR IGNORE INTO repos (id, full_name, default_branch, created_at) VALUES (?, ?, ?, ?)",
		args: ["fairchild/dotfiles", "fairchild/dotfiles", "main", hoursAgo(30)],
	});
	const sessions = [
		["seed-resume", "fairchild/workspaces", "Fix the session-resume path", "active", 2],
		["seed-masthead", "fairchild/dotfiles", "Ship the Folio masthead", "idle", 26],
	];
	for (const [id, repoId, title, status, hours] of sessions) {
		await db.execute({
			sql: `INSERT INTO sessions
				(id, repo_id, title, provider, status, claude_session_id, created_at, last_activity_at)
				VALUES (?, ?, ?, 'mock', ?, NULL, ?, ?)`,
			args: [id, repoId, title, status, hoursAgo(hours + 1), hoursAgo(hours)],
		});
	}
}

// --- captures ------------------------------------------------------------------

async function captureSettled(page, url, file) {
	await page.goto(url, { waitUntil: "networkidle" });
	await page.waitForTimeout(ANIMATION_SETTLE_MS);
	await page.screenshot({ path: file });
}

/** Drives the real new-session flow and captures the empty session it makes. */
async function captureNewSessionFlow(page, file) {
	await page.goto("/", { waitUntil: "networkidle" });
	await page
		.getByRole("textbox", { name: "Repository (owner/name)" })
		.fill("fairchild/workspaces");
	await page.keyboard.press("Enter");
	await page.waitForURL(/\/sessions\//, { timeout: TURN_TIMEOUT_MS });
	await page.waitForTimeout(ANIMATION_SETTLE_MS);
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
	const { env, databaseUrl } = bypassServerEnv("evidence-db");
	const server = await startProductionServer(PORT, env);
	const db = await connectSeedClient(server.baseUrl, databaseUrl);
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
			await context.addCookies([testAuthCookie(server.baseUrl)]);
			await routeFontsThroughCurl(context);
			const page = await context.newPage();
			const shot = (name) => path.join(OUTPUT_DIR, `${name}-${colorScheme}.png`);

			await wipeRows(db);
			await captureSettled(page, "/", shot("home-empty"));
			await captureNewSessionFlow(page, shot("session-empty"));
			await seedPopulatedHome(db);
			await captureSettled(page, "/", shot("home-populated"));

			await captureSpikeAfterTurn(page, shot("spike"));
			await captureSettled(page, "/sessions/demo", shot("sessions-demo"));
			await capturePrototype(page, colorScheme, shot("prototype-folio"));
			await context.close();
			console.log(
				`captured home (empty+populated) + session-empty + spike + sessions-demo + prototype (${colorScheme})`,
			);
		}
	} finally {
		await browser.close();
		await server.stop();
		db.close();
	}
	console.log(`evidence written to ${OUTPUT_DIR}`);
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
