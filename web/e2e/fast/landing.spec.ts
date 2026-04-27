import { expect, test } from "@playwright/test";

test.describe("Landing page", () => {
	test("loads with Spaces branding", async ({ page }) => {
		await page.goto("/");
		await expect(page.getByText("Spaces", { exact: true }).first()).toBeVisible();
	});

	test("links to login", async ({ page }) => {
		await page.goto("/");
		const loginLink = page.getByRole("link", { name: /> login/i });

		await expect(loginLink).toBeVisible();
		await expect(loginLink).toHaveAttribute("href", "/sign-in");
	});
});
