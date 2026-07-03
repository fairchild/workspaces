/*
 * Sessions home + new-session flow + the live session surface, as one serial
 * story over a database this file owns: it wipes the session/repo rows up
 * front (the e2e server keeps running between local runs), then walks
 * empty state → create via typed owner/name → empty session surface →
 * populated home → create via repo picker → a streamed mock turn →
 * reload-persistence (post-turn and mid-turn).
 */
import { createClient } from "@libsql/client";
import path from "node:path";
import { expect, test } from "@playwright/test";

// Serial: these tests narrate one stateful flow over the shared e2e DB.
test.describe.configure({ mode: "serial" });

const SESSION_URL = /\/sessions\/[0-9a-f-]{36}$/;

// The mock turn takes ~7s of scripted delays end to end.
const TURN_TIMEOUT = 20_000;

test.beforeAll(async () => {
	// Same file the e2e server opened (see e2e:server); libSQL file handles
	// are plain SQLite, safe to write from a second process.
	const db = createClient({
		url: `file:${path.resolve(__dirname, "../../.data/e2e.db")}`,
	});
	for (const table of ["session_events", "sessions", "repos"]) {
		await db.execute(`DELETE FROM ${table}`);
	}
	db.close();
});

test("an empty home shows the calm empty state with the picker open", async ({
	page,
}) => {
	await page.goto("/");
	await expect(page.getByText("No sessions yet.")).toBeVisible();
	await expect(page.getByTestId("new-session-picker")).toBeVisible();
	await expect(
		page.getByRole("textbox", { name: "Repository (owner/name)" }),
	).toBeVisible();
});

test("typing an owner/name creates the repo + session and routes to it", async ({
	page,
}) => {
	await page.goto("/");
	await page
		.getByRole("textbox", { name: "Repository (owner/name)" })
		.fill("fairchild/workspaces");
	await page.keyboard.press("Enter");

	await expect(page).toHaveURL(SESSION_URL);
	// The empty Folio session: masthead repo, calm note, autofocused compose.
	await expect(page.locator("header")).toContainText("fairchild/workspaces");
	await expect(page.locator("header")).toContainText("New session");
	await expect(page.getByTestId("empty-transcript")).toContainText(
		"No turns yet.",
	);
	await expect(
		page.getByRole("textbox", { name: "Reply to Claude" }),
	).toBeFocused();
});

test("home lists the session and the picker now offers the repo", async ({
	page,
}) => {
	await page.goto("/");
	const row = page.getByRole("link", { name: /Untitled session/ });
	await expect(row).toContainText("fairchild/workspaces");
	await expect(row).toContainText(/just now|\dm ago/);

	// The affordance is quiet until asked; the connected repo is one click.
	await page.getByRole("button", { name: "+ new session" }).click();
	await page
		.getByTestId("new-session-picker")
		.getByRole("button", { name: "fairchild/workspaces" })
		.click();
	await expect(page).toHaveURL(SESSION_URL);

	// Two sessions now, newest first.
	await page.goto("/");
	await expect(page.getByRole("link", { name: /Untitled session/ })).toHaveCount(
		2,
	);
});

// The session the streamed-turn tests share, set by the first of them.
let turnSessionUrl = "";

test("sending a message streams a mock coding turn into the Folio transcript", async ({
	page,
}) => {
	await page.goto("/");
	await page
		.getByRole("link", { name: /Untitled session/ })
		.first()
		.click();
	await expect(page).toHaveURL(SESSION_URL);
	turnSessionUrl = page.url();

	const compose = page.getByRole("textbox", { name: "Reply to Claude" });
	await compose.fill("Fix the failing session test");
	await page.keyboard.press("Enter");

	// The user message lands at once; compose clears and holds while busy.
	await expect(page.locator('[data-message-role="user"]')).toContainText(
		"Fix the failing session test",
	);
	await expect(page.getByTestId("empty-transcript")).toHaveCount(0);
	await expect(compose).toHaveValue("");
	await expect(page.getByRole("button", { name: "Send" })).toBeDisabled();

	// The activity line breathes while the provider provisions.
	await expect(page.getByTestId("activity-line")).toBeVisible();

	// The turn streams the whole apparatus: prose…
	await expect(page.locator('[data-message-role="assistant"]')).toContainText(
		"Let me look at the failing test",
		{ timeout: TURN_TIMEOUT },
	);
	// …the tool ledger (Read, Edit with its line delta, Ran)…
	const rows = page.getByTestId("tool-row");
	await expect(rows).toHaveCount(3, { timeout: TURN_TIMEOUT });
	await expect(rows.nth(0)).toContainText("Read");
	await expect(rows.nth(1)).toContainText("+3 −1");
	await expect(rows.nth(2)).toContainText("Ran");
	await expect(rows.nth(2)).toContainText("pnpm test session");
	// …the landed diff card…
	await expect(page.getByTestId("diff-card")).toContainText(
		"SessionNotFoundError",
		{ timeout: TURN_TIMEOUT },
	);
	// …and the end-of-turn receipt derived from the stream.
	await expect(page.getByTestId("turn-stats")).toContainText(
		"3 tools · 1 file · +3 −1 · 4 tests",
		{ timeout: TURN_TIMEOUT },
	);

	// The test run discloses the highlighted output panel.
	await rows.nth(2).locator("button").first().click();
	await expect(page.getByTestId("test-output")).toContainText("4 passed");
	await expect(page.getByTestId("test-output")).toHaveAttribute(
		"data-passed",
		"true",
	);

	// Turn over: compose re-enables, the activity line is gone.
	await expect(page.getByRole("button", { name: "Send" })).toBeEnabled();
	await expect(page.getByTestId("activity-line")).toHaveCount(0);
});

test("a reload renders the same turn from the persisted event log", async ({
	page,
}) => {
	await page.goto(turnSessionUrl);
	await expect(page.locator('[data-message-role="user"]')).toContainText(
		"Fix the failing session test",
	);
	await expect(page.getByTestId("tool-row")).toHaveCount(3);
	await expect(page.getByTestId("diff-card")).toContainText("src/lib/session.ts");
	await expect(page.getByTestId("turn-stats")).toContainText(
		"3 tools · 1 file · +3 −1 · 4 tests",
	);
	// Nothing is in flight after a reload — the receipt is served, not replayed.
	await expect(page.getByTestId("activity-line")).toHaveCount(0);
});

test("reloading mid-turn keeps the persisted prefix of the interrupted turn", async ({
	page,
}) => {
	await page.goto(turnSessionUrl);
	const compose = page.getByRole("textbox", { name: "Reply to Claude" });
	await compose.fill("Now add a regression test");
	await page.keyboard.press("Enter");

	// Wait until the second turn's first tool call landed in the log…
	await expect(page.getByTestId("tool-row")).toHaveCount(4, {
		timeout: TURN_TIMEOUT,
	});
	// …then abandon the stream mid-turn.
	await page.reload();

	// Both turns' user messages survive; the interrupted turn shows the
	// prefix that reached the event log (its opening prose at least).
	await expect(page.locator('[data-message-role="user"]')).toHaveCount(2);
	await expect(
		page.locator('[data-message-role="assistant"]').nth(1),
	).toContainText('You asked: "Now add a regression test"');
	// No receipt for a turn that never finished.
	await expect(page.getByTestId("turn-stats")).toHaveCount(1);
});
