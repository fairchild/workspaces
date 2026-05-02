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

	test("starts social login from the served origin", async ({ page }) => {
		test.skip(
			process.env.PLAYWRIGHT_SKIP_WEB_SERVER === "1",
			"local server origin regression only",
		);

		await page.goto("/sign-in");

		const response = await page.request.post("/api/auth/sign-in/social", {
			data: { provider: "github", callbackURL: "/dashboard" },
			headers: {
				Origin: new URL(page.url()).origin,
			},
		});

		expect(response.status()).not.toBe(403);
		expect(response.status()).toBeLessThan(500);
	});
});
