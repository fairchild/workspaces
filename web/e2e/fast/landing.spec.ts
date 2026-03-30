import { expect, test } from "@playwright/test";

test.describe("Landing page @fast", () => {
	test("loads with Spaces branding", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByText("Spaces", { exact: true }).first()).toBeVisible();
	});
});
