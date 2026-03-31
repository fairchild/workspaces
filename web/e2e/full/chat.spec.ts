import { expect, test } from "@playwright/test";

test.describe("Chat (authenticated)", () => {
	test("tab switching updates URL", async ({ page }) => {
		await page.goto("/dashboard");
		await expect(page.getByRole("button", { name: "Dashboard" })).toBeVisible();

		await page.getByRole("button", { name: "Chat" }).click();
		await expect(page).toHaveURL(/tab=chat/);

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
	});

	test("timeline shows day separators with seeded data", async ({ page }) => {
		await page.goto("/dashboard/fairchild/workspaces?tab=chat");
		// Wait for timeline to load (seeded messages span 2 days)
		await page.waitForTimeout(2000);
		const separators = page.locator("[class*='daySeparator']");
		const count = await separators.count();
		// Should have at least 1 day separator (messages span 2 days)
		expect(count).toBeGreaterThanOrEqual(1);
	});

	test.skip("compose bar @ mention triggers autocomplete", async ({
		page,
	}) => {
		// TODO: Requires GitHub API for agent discovery — agents come from
		// .agents/skills/ in the repo, fetched via GitHub token. Can't seed
		// locally without mocking the GitHub API.
	});
});
