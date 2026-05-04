import { expect, test } from "@playwright/test";

test.describe("Deployment smoke landing", () => {
	test("serves the Spaces landing page with a sign-in path", async ({ page }) => {
		await page.goto("/");

		await expect(page.getByText("Spaces", { exact: true }).first()).toBeVisible();
		await expect(page.getByRole("link", { name: /> login/i })).toHaveAttribute(
			"href",
			"/sign-in",
		);
	});

	test("redirects dashboard visitors without a session to sign-in", async ({
		page,
	}) => {
		await page.goto("/dashboard");

		await expect(page).toHaveURL(/\/sign-in/);
	});
});
