import { expect, test } from "@playwright/test";

/**
 * Video demo: Chat timeline with collapsed events
 *
 * Records a walkthrough showing:
 * 1. Dashboard → Chat tab switch with autofocus
 * 2. Timeline with collapsed event groups and chat messages
 * 3. Expanding/collapsing event groups
 * 4. Typing a message and interacting with compose bar
 * 5. Scrolling through the timeline
 *
 * Run: pnpm exec playwright test --project=demo
 * Output: test-results/ contains .webm videos
 */
test("chat timeline walkthrough", async ({ page }) => {
	// Start at dashboard
	await page.goto("/dashboard/fairchild/workspaces");
	await page.waitForLoadState("networkidle");
	await page.waitForTimeout(1000);

	// Switch to Chat tab
	await page.locator("nav button", { hasText: "Chat" }).click();
	await page.waitForTimeout(1500);

	// Wait for timeline to load
	await page.waitForTimeout(2000);

	// Scroll to top to show full timeline
	const container = page.locator("[class*='container']").first();
	await container.evaluate((el) => el.scrollTo(0, 0));
	await page.waitForTimeout(1000);

	// Slowly scroll through the timeline
	await container.evaluate((el) => el.scrollTo({ top: el.scrollHeight * 0.3, behavior: "smooth" }));
	await page.waitForTimeout(1500);

	// Expand a collapsed event group
	const groups = page.locator("button[class*='group']");
	if ((await groups.count()) > 0) {
		const firstGroup = groups.first();
		await firstGroup.scrollIntoViewIfNeeded();
		await page.waitForTimeout(500);
		await firstGroup.click();
		await page.waitForTimeout(1500);

		// Collapse it again
		await firstGroup.click();
		await page.waitForTimeout(1000);
	}

	// Scroll to bottom to see latest messages
	await container.evaluate((el) => el.scrollTo({ top: el.scrollHeight, behavior: "smooth" }));
	await page.waitForTimeout(1500);

	// Interact with compose bar
	const textarea = page.getByPlaceholder("Type a message or @mention an agent");
	await textarea.click();
	await page.waitForTimeout(500);

	// Type a message slowly for the video
	await textarea.pressSequentially("@april-clearwater what's the project status?", { delay: 50 });
	await page.waitForTimeout(1500);

	// Clear and show plain message
	await textarea.fill("");
	await page.waitForTimeout(300);
	await textarea.pressSequentially("Looking good! The collapsed events make the chat much more usable.", { delay: 40 });
	await page.waitForTimeout(2000);

	// Switch back to dashboard briefly
	await page.locator("nav button", { hasText: "Dashboard" }).click();
	await page.waitForTimeout(1000);

	// Return to chat
	await page.locator("nav button", { hasText: "Chat" }).click();
	await page.waitForTimeout(1500);
});

test("event group expand/collapse demo", async ({ page }) => {
	await page.goto("/dashboard/fairchild/workspaces?tab=chat");
	await page.waitForTimeout(2500);

	// Find all collapsed groups
	const groups = page.locator("button[class*='group']");
	const count = await groups.count();

	// Expand each group one at a time
	for (let i = 0; i < Math.min(count, 3); i++) {
		const group = groups.nth(i);
		await group.scrollIntoViewIfNeeded();
		await page.waitForTimeout(500);
		await group.click();
		await page.waitForTimeout(1200);
	}

	// Pause to show all expanded
	await page.waitForTimeout(1500);

	// Collapse them back
	for (let i = Math.min(count, 3) - 1; i >= 0; i--) {
		const group = groups.nth(i);
		await group.click();
		await page.waitForTimeout(800);
	}

	await page.waitForTimeout(1000);
});

test("compose bar interaction demo", async ({ page }) => {
	await page.goto("/dashboard/fairchild/workspaces?tab=chat");
	await page.waitForTimeout(2000);

	const textarea = page.getByPlaceholder("Type a message or @mention an agent");

	// Show autofocus
	await expect(textarea).toBeFocused({ timeout: 3000 });
	await page.waitForTimeout(500);

	// Type an @mention
	await textarea.pressSequentially("@", { delay: 100 });
	await page.waitForTimeout(800);

	// Continue typing agent name
	await textarea.pressSequentially("april", { delay: 80 });
	await page.waitForTimeout(1000);

	// Clear and type regular message
	await textarea.fill("");
	await page.waitForTimeout(300);
	await textarea.pressSequentially("Just a regular message", { delay: 50 });
	await page.waitForTimeout(800);

	// Show shift+enter for newline
	await textarea.press("Shift+Enter");
	await textarea.pressSequentially("with a second line", { delay: 50 });
	await page.waitForTimeout(1500);
});
