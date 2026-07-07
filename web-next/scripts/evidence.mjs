/*
 * Evidence capture, light + dark: the sessions home (empty and populated),
 * an empty session reached through the real new-session flow, a real mock
 * turn streamed into that session (mid-stream, final, and reloaded from the
 * event log), the durable disconnect→resume story (tab closed mid-turn, a
 * fresh tab catching up, then completed), the Folio session demo, and the
 * refine-folio prototype beside it for pixel comparison. Runs against a
 * production build in auth-bypass
 * mode over a throwaway database. Output goes to output/evidence/
 * (gitignored); CI uploads it as an artifact — the sanctioned publish path
 * per docs/development/remote-sessions.md.
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

/**
 * Streams a real mock turn in the session the new-session flow just made
 * (the page is already on it): mid-stream while the activity line breathes,
 * mid-stream as ledger rows land, final with the receipt + disclosed test
 * output, and reloaded — the same turn re-rendered from the event log.
 */
async function captureSessionTurn(page, shot) {
	await page.getByRole("textbox", { name: "Reply to Claude" }).fill(
		"Fix the failing session test",
	);
	await page.keyboard.press("Enter");

	// Mid-stream, early: the provisioning activity line. The provisioning
	// window is ~650ms, so give the 0.55s rise animation most of its run
	// without letting the first prose token close the window.
	await page.getByTestId("activity-line").waitFor({ timeout: TURN_TIMEOUT_MS });
	await page.waitForTimeout(350);
	await page.screenshot({ path: shot("session-turn-streaming") });

	// Mid-stream, later: two ledger rows landed, the turn still open.
	await page.waitForFunction(
		() =>
			document.querySelectorAll('[data-testid="tool-row"]').length >= 2 &&
			document.querySelector('[data-testid="turn-stats"]') === null,
		undefined,
		{ timeout: TURN_TIMEOUT_MS },
	);
	await page.screenshot({ path: shot("session-turn-midstream") });

	// Final: receipt rendered; disclose the passing re-run's output panel
	// (the mock turn is: failed run, Read, Edit, passing run).
	await page.getByTestId("turn-stats").waitFor({ timeout: TURN_TIMEOUT_MS });
	await page.getByTestId("tool-row").nth(3).locator("button").first().click();
	await page.getByTestId("test-output").waitFor();
	// Scroll to the end of the turn so diff card + receipt are in frame.
	await page.getByTestId("turn-stats").scrollIntoViewIfNeeded();
	await page.waitForTimeout(ANIMATION_SETTLE_MS);
	await page.screenshot({ path: shot("session-turn-final") });

	// Reloaded: the persisted transcript served from session_events.
	await page.reload({ waitUntil: "networkidle" });
	await page.getByTestId("turn-stats").scrollIntoViewIfNeeded();
	await page.waitForTimeout(ANIMATION_SETTLE_MS);
	await page.screenshot({ path: shot("session-turn-reloaded") });
}

/**
 * The terminal drawer (#752), on the session the turn just ran in: Ctrl+`
 * opens it (lazy ghostty-web init + the ticket mint/redeem exchange over the
 * mock PTY seam), a command runs in the shell, and the drawer is captured
 * over the transcript.
 */
async function captureTerminalDrawer(page, file) {
	await page.keyboard.press("Control+Backquote");
	await page.waitForFunction(
		() =>
			document.querySelector('[data-testid="terminal-drawer"]')?.dataset
				.ready === "true",
		undefined,
		{ timeout: TURN_TIMEOUT_MS },
	);
	await page.keyboard.type("echo hello from the session sandbox");
	await page.keyboard.press("Enter");
	await page.keyboard.type("pwd");
	await page.keyboard.press("Enter");
	await page.waitForTimeout(ANIMATION_SETTLE_MS);
	await page.screenshot({ path: file });
	// Leave the page as we found it for the captures that follow.
	await page.keyboard.press("Control+Backquote");
}

/**
 * The durable-turn story: start a turn, close the tab mid-stream, reopen the
 * session in a fresh tab and watch it catch up and complete. Manages its own
 * pages (the starter tab is closed on purpose) so the caller's page is left
 * untouched; the reopened tab inherits the context's theme + font routing.
 */
async function captureDisconnectResume(context, shot) {
	const starter = await context.newPage();
	await starter.goto("/", { waitUntil: "networkidle" });
	await starter.getByRole("button", { name: "+ new session" }).click();
	await starter
		.getByTestId("new-session-picker")
		.getByRole("button", { name: "fairchild/workspaces" })
		.click();
	await starter.waitForURL(/\/sessions\//, { timeout: TURN_TIMEOUT_MS });
	const sessionUrl = starter.url();

	await starter
		.getByRole("textbox", { name: "Reply to Claude" })
		.fill("Fix the failing session test");
	await starter.keyboard.press("Enter");
	// Mid-turn: first prose streamed — the moment before the tab is closed.
	await starter
		.getByText("Let me reproduce the failure first")
		.waitFor({ timeout: TURN_TIMEOUT_MS });
	await starter.waitForTimeout(300);
	await starter.screenshot({ path: shot("resume-midturn") });

	// Close the tab entirely; the detached turn keeps running server-side.
	await starter.close();
	const reopened = await context.newPage();
	await reopened.goto(sessionUrl, { waitUntil: "commit" });
	// Catching up: the reopened tab resumes the in-flight turn from the log.
	await reopened
		.getByTestId("activity-line")
		.waitFor({ timeout: TURN_TIMEOUT_MS })
		.catch(() => {});
	await reopened.waitForTimeout(300);
	await reopened.screenshot({ path: shot("resume-catchup") });

	// Completed: the resumed turn finished; the receipt proves it caught up.
	await reopened.getByTestId("turn-stats").waitFor({ timeout: TURN_TIMEOUT_MS });
	await reopened.getByTestId("turn-stats").scrollIntoViewIfNeeded();
	await reopened.waitForTimeout(ANIMATION_SETTLE_MS);
	await reopened.screenshot({ path: shot("resume-complete") });
	await reopened.close();
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
			await captureSessionTurn(page, shot);
			await captureTerminalDrawer(page, shot("session-terminal-drawer"));
			await captureDisconnectResume(context, shot);
			await seedPopulatedHome(db);
			await captureSettled(page, "/", shot("home-populated"));

			await captureSettled(page, "/sessions/demo", shot("sessions-demo"));
			await capturePrototype(page, colorScheme, shot("prototype-folio"));
			await context.close();
			console.log(
				`captured home (empty+populated) + session (empty, streaming, final, reloaded) + disconnect→resume (midturn, catchup, complete) + sessions-demo + prototype (${colorScheme})`,
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
