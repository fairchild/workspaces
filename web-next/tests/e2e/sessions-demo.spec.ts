/*
 * E2E for the Folio session demo (/sessions/demo): theme resolution
 * (toggle, persistence, #light/#dark hash parity), autofocused bare
 * compose, ledger row disclosure, diff card dismissal, status line
 * dismiss-to-dot, and the focus cue / receipt furniture.
 */
import { expect, test } from "@playwright/test";

const theme = (page: import("@playwright/test").Page) =>
	page.locator("html").getAttribute("data-theme");

test("theme: system preference by default, toggle overrides and persists", async ({
	page,
}) => {
	await page.emulateMedia({ colorScheme: "dark" });
	await page.goto("/sessions/demo");
	expect(await theme(page)).toBe("dark");

	const toggle = page.getByRole("button", { name: /toggle light \/ dark/i });
	await toggle.click();
	expect(await theme(page)).toBe("light");

	// The explicit choice survives a reload even though the system says dark.
	await page.reload();
	expect(await theme(page)).toBe("light");
});

test("theme: #light/#dark hash forces the theme like the prototype", async ({
	page,
}) => {
	await page.emulateMedia({ colorScheme: "light" });
	await page.goto("/sessions/demo#dark");
	expect(await theme(page)).toBe("dark");

	await page.goto("/sessions/demo#light");
	expect(await theme(page)).toBe("light");

	// Hash wins over a stored toggle choice on the next load. (A same-hash
	// goto is a same-document navigation — no reload, no hashchange — so
	// reload instead, like a shared #light link being opened.)
	await page.getByRole("button", { name: /toggle light \/ dark/i }).click();
	expect(await theme(page)).toBe("dark");
	await page.reload();
	expect(await theme(page)).toBe("light");
});

test("compose autofocuses with no placeholder or hint chips", async ({
	page,
}) => {
	await page.goto("/sessions/demo");
	const input = page.getByRole("textbox", { name: "Reply to Claude" });
	await expect(input).toBeFocused();
	await expect(input).not.toHaveAttribute("placeholder", /./);
	// No hint chips ride inside the field: caret, input, send button only.
	expect(
		await page.locator("footer input ~ *, footer button").count(),
	).toBeLessThanOrEqual(2);
});

test("tool ledger rows disclose and collapse their bodies", async ({
	page,
}) => {
	await page.goto("/sessions/demo");

	// The landed test run starts open, per the fixture.
	const openBody = page.getByTestId("test-output");
	await expect(openBody).toBeVisible();
	await expect(openBody).toContainText("28 passed");

	const readRow = page
		.getByRole("button", { name: /Read src\/session\/session\.test\.ts/ })
		.first();
	await readRow.click();
	const readBody = page
		.getByTestId("tool-row")
		.filter({ has: readRow })
		.getByTestId("tool-row-body");
	await expect(readBody).toBeVisible();
	await expect(readBody).toContainText("rejects when the session id is unknown");
	await readRow.click();
	await expect(readBody).toBeHidden();
});

test("diff card renders the landed edit and dismisses", async ({ page }) => {
	await page.goto("/sessions/demo");
	const card = page.getByTestId("diff-card");
	await expect(card).toContainText("src/session/resume.ts");
	await expect(card).toContainText("throw new SessionNotFoundError(id);");
	await card.hover();
	await card.getByRole("button", { name: /dismiss/i }).click();
	await expect(card).toHaveCount(0);
});

test("status line dismisses to a dot and comes back", async ({ page }) => {
	await page.goto("/sessions/demo");
	const statusLine = page.getByTestId("status-line");
	await expect(statusLine).toContainText("opus-4.8");

	await statusLine.getByRole("button", { name: /hide status line/i }).click();
	await expect(statusLine).toHaveCount(0);

	const handle = page.getByTestId("status-line-handle");
	await expect(handle).toBeVisible();
	await handle.click();
	await expect(page.getByTestId("status-line")).toContainText("2.1k ctx");
});

test("focus cue and end-of-turn receipt are present", async ({ page }) => {
	await page.goto("/sessions/demo");
	// The completed agent turn and the working turn carry the gutter tick.
	await expect(page.locator("[data-focal]")).toHaveCount(2);
	await expect(page.getByTestId("turn-stats")).toHaveText(
		"4 tools · 3.2k tokens · 18.6s",
	);
	// The in-progress turn shows the quiet activity line.
	await expect(page.getByTestId("activity-line")).toContainText("Editing");
});

test("seeded transcript renders the requested message count", async ({
	page,
}) => {
	await page.goto("/sessions/demo?seed=20");
	await expect(page.locator("[data-message-role]")).toHaveCount(20);
});
