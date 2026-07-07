/*
 * The phone-width contract (#753): at 375px the whole session surface —
 * home, transcript with a real streamed turn (prose, reasoning, ledger
 * rows, an expanded diff and test output — the widest content the app
 * renders), compose, and the failure card — works with NO horizontal
 * scroll at the page level. Wide content scrolls inside its own panel,
 * never by dragging the page sideways.
 */
import { expect, type Page, test } from "@playwright/test";

test.use({ viewport: { width: 375, height: 812 } });

const TURN_TIMEOUT = 20_000;

/** Page-level horizontal overflow in px (0 = none). */
function horizontalOverflow(page: Page): Promise<number> {
	return page.evaluate(() => {
		const root = document.documentElement;
		return Math.max(
			root.scrollWidth - root.clientWidth,
			document.body.scrollWidth - root.clientWidth,
		);
	});
}

async function expectNoHorizontalScroll(page: Page, where: string): Promise<void> {
	expect(await horizontalOverflow(page), `horizontal overflow ${where}`).toBe(0);
}

async function createSession(page: Page): Promise<void> {
	await page.goto("/");
	const picker = page.getByTestId("new-session-picker");
	if (!(await picker.isVisible())) {
		await page.getByRole("button", { name: "+ new session" }).click();
	}
	await page
		.getByRole("textbox", { name: "Repository (owner/name)" })
		.fill("fairchild/workspaces");
	await page.keyboard.press("Enter");
	await expect(page).toHaveURL(/\/sessions\/[0-9a-f-]{36}$/);
}

test("transcript + compose hold up at 375px through a full turn, with no horizontal scroll", async ({
	page,
}) => {
	await createSession(page);
	await expectNoHorizontalScroll(page, "on the empty session");

	// Compose is usable: autofocused, and the send affordance is in reach.
	const compose = page.getByRole("textbox", { name: "Reply to Claude" });
	await expect(compose).toBeFocused();
	await expect(page.getByRole("button", { name: "Send" })).toBeVisible();

	// Stream a full mock turn — prose, reasoning, four ledger rows, receipt.
	await compose.fill("Fix the failing session test");
	await page.keyboard.press("Enter");
	await expect(page.getByTestId("turn-stats")).toContainText("4 tools", {
		timeout: TURN_TIMEOUT,
	});
	await expectNoHorizontalScroll(page, "after the streamed turn");

	// Open the widest content the transcript renders: the landed edit's diff
	// and the highlighted test output. Each scrolls inside its own panel.
	const rows = page.getByTestId("tool-row");
	await rows.nth(2).locator("button").first().click();
	await expect(rows.nth(2).getByTestId("diff-lines")).toBeVisible();
	await rows.nth(3).locator("button").first().click();
	await expect(page.getByTestId("test-output")).toBeVisible();
	await expectNoHorizontalScroll(page, "with diff + test output expanded");

	// The thinking block expands and reads within the frame too.
	await page.getByTestId("reasoning").locator("button").first().click();
	await expectNoHorizontalScroll(page, "with the reasoning block open");

	// Compose still works after the turn: a draft types cleanly at 375px.
	await compose.click();
	await compose.fill("And now add a regression test for it");
	await expect(compose).toHaveValue("And now add a regression test for it");
	await expectNoHorizontalScroll(page, "with a draft in compose");
});

test("the failure card fits and stays actionable at 375px", async ({ page }) => {
	await createSession(page);
	const compose = page.getByRole("textbox", { name: "Reply to Claude" });
	await compose.fill("Build it __mock_provision_error__");
	await page.keyboard.press("Enter");

	await expect(page.getByTestId("turn-failure")).toContainText(
		"Sandbox provisioning failed",
		{ timeout: TURN_TIMEOUT },
	);
	await expect(page.getByRole("button", { name: "Retry" })).toBeVisible();
	await expectNoHorizontalScroll(page, "with the failure card shown");
});

test("home renders within 375px", async ({ page }) => {
	await page.goto("/");
	await expectNoHorizontalScroll(page, "on the sessions home");
});
