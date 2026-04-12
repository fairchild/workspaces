import { expect, test } from "@playwright/test";

test.describe("Auth redirect", () => {
	test("GET /dashboard without auth redirects to sign-in", async ({
		page,
	}) => {
		await page.goto("/dashboard");
		await expect(page).toHaveURL(/\/sign-in/);
	});
});
