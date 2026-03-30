import { expect, test } from "@playwright/test";

test.describe("Chat (authenticated)", () => {
	test("tab switching updates URL", async ({ page }) => {
		await page.goto("/dashboard");
		await expect(page.getByRole("button", { name: "Dashboard" })).toBeVisible();

		// Switch to Chat
		await page.getByRole("button", { name: "Chat" }).click();
		await expect(page).toHaveURL(/tab=chat/);

		// Switch back to Dashboard
		await page.getByRole("button", { name: "Dashboard" }).click();
		await expect(page).not.toHaveURL(/tab=chat/);
	});

	test("chat tab shows compose bar", async ({ page }) => {
		await page.goto("/dashboard?tab=chat");
		await expect(
			page.getByPlaceholder("Type a message or @mention an agent"),
		).toBeVisible();
		await expect(page.getByRole("button", { name: "Send" })).toBeVisible();
	});

	test("compose bar shows helper text", async ({ page }) => {
		await page.goto("/dashboard?tab=chat");
		await expect(page.getByText("Enter to send")).toBeVisible();
		await expect(page.getByText("@ to mention agent")).toBeVisible();
	});

	test.skip("sticky tab bar stays visible while scrolling", async ({
		page,
	}) => {
		// TODO: Needs seeded timeline entries to create scrollable content
		// 1. Navigate to chat tab with long timeline
		// 2. Scroll down significantly
		// 3. Verify tab bar is still in viewport
	});

	test.skip("timeline shows day separators", async ({ page }) => {
		// TODO: Needs seeded chat messages spanning multiple days
		// 1. Navigate to chat tab
		// 2. Verify .daySeparator elements exist
		// 3. Verify separator text matches "Mon DD" format
	});

	test.skip("compose bar @ mention triggers autocomplete", async ({
		page,
	}) => {
		// TODO: Needs seeded agents via repo with .agents/ directory
		// 1. Click compose bar textarea
		// 2. Type "@"
		// 3. Verify autocomplete dropdown appears
		// 4. Select an agent
		// 5. Verify agent chip appears
	});
});
