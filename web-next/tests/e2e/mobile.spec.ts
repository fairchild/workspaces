/*
 * The phone-width contract (#753): at 375px the whole session surface —
 * home, transcript with a real streamed turn (prose, reasoning, ledger
 * rows, an expanded diff and test output — the widest content the app
 * renders), compose, and the failure card — works with NO horizontal
 * scroll at the page level. Wide content scrolls inside its own panel,
 * never by dragging the page sideways.
 */
import { expect, type Locator, type Page, test } from "@playwright/test";

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

async function expectAfterHitArea(locator: Locator, name: string): Promise<void> {
	const size = await locator.evaluate((element) => {
		const style = getComputedStyle(element, "::after");
		return {
			height: Number.parseFloat(style.height),
			width: Number.parseFloat(style.width),
		};
	});
	expect(size.width, `${name} hit-area width`).toBeGreaterThanOrEqual(44);
	expect(size.height, `${name} hit-area height`).toBeGreaterThanOrEqual(44);
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

test("mobile status chrome keeps compose gutter and 44px hit areas", async ({
	page,
}) => {
	await createSession(page);

	const statusLine = page.getByTestId("status-line");
	const rowPadding = await statusLine.evaluate((element) => {
		const row = element.firstElementChild;
		if (!(row instanceof HTMLElement)) return null;
		return getComputedStyle(row).paddingLeft;
	});
	expect(rowPadding, "status row left gutter").toBe("20px");

	await expectAfterHitArea(
		page.getByRole("button", { name: "Toggle light / dark theme" }),
		"theme toggle",
	);

	const hideStatus = statusLine.getByRole("button", { name: "Hide status line" });
	await expectAfterHitArea(hideStatus, "status dismiss");

	await hideStatus.click();
	const handle = page.getByTestId("status-line-handle");
	const handleBox = await handle.boundingBox();
	expect(handleBox, "status handle box").not.toBeNull();
	expect(handleBox?.width, "status handle width").toBeGreaterThanOrEqual(44);
	expect(handleBox?.height, "status handle height").toBeGreaterThanOrEqual(44);

	// Hit-test the real stacking, not just declared geometry: the handle's
	// invisible halo overlaps the send button's lower-right corner, and live
	// controls must win those pixels while the halo keeps the dead strip.
	const hitAt = (x: number, y: number) =>
		page.evaluate(
			([px, py]) => {
				const el = document.elementFromPoint(px, py);
				const target = el?.closest("button, a");
				return (
					target?.getAttribute("data-testid") ??
					target?.getAttribute("aria-label") ??
					null
				);
			},
			[x, y],
		);
	const sendBox = await page
		.getByRole("button", { name: "Send" })
		.boundingBox();
	expect(sendBox, "send button box").not.toBeNull();
	if (sendBox && handleBox) {
		// Inside the halo/send overlap but clear of the button's 10px corner
		// radius — hit-testing honors border-radius, so true corner-arc pixels
		// belong to no button.
		const corner = await hitAt(
			sendBox.x + sendBox.width - 12,
			sendBox.y + sendBox.height - 2,
		);
		expect(corner, "send button owns its overlapped edge").toBe("Send");
		const halo = await hitAt(
			handleBox.x + handleBox.width - 4,
			handleBox.y + handleBox.height / 2,
		);
		expect(halo, "handle owns the dead strip").toBe("status-line-handle");
	}
	// The dot itself still reopens the status line.
	await handle.click();
	await expect(statusLine).toBeVisible();
});

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
