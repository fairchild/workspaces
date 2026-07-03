/*
 * Sessions home + new-session flow + empty session page, as one serial
 * story over a database this file owns: it wipes the session/repo rows up
 * front (the e2e server keeps running between local runs), then walks
 * empty state → create via typed owner/name → empty session surface →
 * populated home → create via repo picker → local compose echo.
 */
import { createClient } from "@libsql/client";
import path from "node:path";
import { expect, test } from "@playwright/test";

// Serial: these tests narrate one stateful flow over the shared e2e DB.
test.describe.configure({ mode: "serial" });

const SESSION_URL = /\/sessions\/[0-9a-f-]{36}$/;

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

test("compose echoes the message locally in the transcript", async ({
	page,
}) => {
	await page.goto("/");
	await page
		.getByRole("link", { name: /Untitled session/ })
		.first()
		.click();
	await expect(page).toHaveURL(SESSION_URL);

	const compose = page.getByRole("textbox", { name: "Reply to Claude" });
	await compose.fill("Fix the failing session test");
	await page.keyboard.press("Enter");

	const message = page.locator('[data-message-role="user"]');
	await expect(message).toContainText("Fix the failing session test");
	await expect(page.getByTestId("empty-transcript")).toHaveCount(0);
	await expect(compose).toHaveValue("");
});
