import { expect, test } from "@playwright/test";

/**
 * Video demo: Terminal tab walkthrough
 *
 * Records a walkthrough showing:
 * 1. Dashboard with three tabs visible
 * 2. Tab switching across Dashboard → Chat → Terminal
 * 3. Terminal empty state (no active sandbox)
 * 4. Keyboard shortcuts (Cmd+1/2/3) for tab switching
 *
 * Run: pnpm exec playwright test --project=demo e2e/demo/terminal-walkthrough.spec.ts
 * Output: test-results/ contains .webm videos
 */
test("terminal tab walkthrough", async ({ page }) => {
	// Start at dashboard with repo selected
	await page.goto("/dashboard/fairchild/workspaces");
	await page.waitForLoadState("networkidle");
	await page.waitForTimeout(1500);

	// Show all three tabs in the tab bar
	const tabBar = page.locator("nav");
	await expect(tabBar.getByRole("button", { name: "Dashboard" })).toBeVisible();
	await expect(tabBar.getByRole("button", { name: "Chat" })).toBeVisible();
	await expect(tabBar.getByRole("button", { name: "Terminal" })).toBeVisible();
	await page.waitForTimeout(1000);

	// Switch to Chat tab
	await tabBar.getByRole("button", { name: "Chat" }).click();
	await page.waitForTimeout(1500);

	// Switch to Terminal tab
	await tabBar.getByRole("button", { name: "Terminal" }).click();
	await page.waitForTimeout(2000);

	// Show the empty state message
	await expect(page.getByText("No active sandbox session")).toBeVisible();
	await page.waitForTimeout(1500);

	// Use keyboard shortcut to go to Dashboard (Cmd+1)
	await page.keyboard.press("Meta+1");
	await page.waitForTimeout(1000);

	// Use keyboard shortcut to go to Chat (Cmd+2)
	await page.keyboard.press("Meta+2");
	await page.waitForTimeout(1000);

	// Use keyboard shortcut to go to Terminal (Cmd+3)
	await page.keyboard.press("Meta+3");
	await page.waitForTimeout(1500);

	// Show Terminal tab is active
	await expect(
		tabBar.getByRole("button", { name: "Terminal" }),
	).toHaveClass(/tabActive|Active/);
	await page.waitForTimeout(1500);

	// Go back to Dashboard to end
	await tabBar.getByRole("button", { name: "Dashboard" }).click();
	await page.waitForTimeout(1000);
});
