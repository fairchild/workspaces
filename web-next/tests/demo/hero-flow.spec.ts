/*
 * The hero flow, filmed: home → new session on a real repo → a real
 * vercel-sandbox agent turn → end-of-turn checkpoint → "Open PR" → the
 * draft-PR masthead line. Runs only via playwright.hero.config.ts against
 * a server on the real vercel provider; never part of the hermetic suite.
 */
import { expect, test } from "@playwright/test";

const REPO = process.env.HERO_DEMO_REPO ?? "fairchild/workspaces";
const TURN_TIMEOUT = 15 * 60_000;

const PROMPT =
	"Create a new file demos/web-next-hero-flow.md containing a short note " +
	"(3-4 lines) saying this file was created by a live web-next hero-flow " +
	"demo: a Playwright-driven browser session created this agent session, " +
	"sent this message, and opened the pull request you are reading. " +
	"Do not change anything else.";

test("hero flow: new session → real agent turn → draft PR", async ({ page }) => {
	await page.goto("/");
	await page.waitForTimeout(1500);

	const picker = page.getByTestId("new-session-picker");
	if (!(await picker.isVisible())) {
		await page.getByRole("button", { name: "+ new session" }).click();
	}
	const repoInput = page.getByRole("textbox", { name: "Repository (owner/name)" });
	await repoInput.pressSequentially(REPO, { delay: 40 });
	await page.keyboard.press("Enter");
	await expect(page).toHaveURL(/\/sessions\/[0-9a-f-]{36}$/);

	const compose = page.getByRole("textbox", { name: "Reply to Claude" });
	await compose.click();
	await compose.pressSequentially(PROMPT, { delay: 6 });
	await page.waitForTimeout(500);
	await page.getByRole("button", { name: "Send" }).click();

	// The real turn: sandbox provisioning, clone, the agent's edit, and the
	// end-of-turn checkpoint commit + push.
	await expect(page.getByTestId("turn-stats")).toBeVisible({
		timeout: TURN_TIMEOUT,
	});
	await page.waitForTimeout(2500);

	// The completed turn refreshes its durable session snapshot and arms the
	// affordance in place — no page reload or transcript discontinuity.
	const openPr = page.getByTestId("open-session-pr");
	await expect(openPr).toBeEnabled({ timeout: 3 * 60_000 });
	await page.waitForTimeout(1500);
	await openPr.click();

	const prLine = page.getByTestId("session-pr-line");
	await expect(prLine).toContainText(/PR #\d+/, { timeout: 5 * 60_000 });
	const href = await prLine.getByRole("link").first().getAttribute("href");
	console.log(`HERO_DEMO_PR_URL=${href}`);
	await page.waitForTimeout(5000);
});
