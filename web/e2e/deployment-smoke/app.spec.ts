import { expect, test } from "@playwright/test";

test.describe("Deployment smoke", () => {
	test.describe.configure({ mode: "serial" });

	test("serves the landing page and sign-in affordance", async ({ page }) => {
		await page.goto("/");

		await expect(page.getByText("Spaces", { exact: true }).first()).toBeVisible();
		await expect(page.getByRole("link", { name: /login/i })).toHaveAttribute(
			"href",
			"/sign-in",
		);
	});

	test("serves the sign-in page", async ({ page }) => {
		await page.goto("/sign-in");

		await expect(page.getByRole("heading", { name: "Spaces" })).toBeVisible();
		await expect(
			page.getByRole("button", { name: "Continue with GitHub" }),
		).toBeVisible();
	});

	test("redirects unauthenticated dashboard requests to sign-in", async ({
		page,
	}) => {
		test.skip(
			process.env.PLAYWRIGHT_SKIP_WEB_SERVER !== "1",
			"local Playwright webServer runs with DEV_BYPASS_AUTH=1",
		);

		await page.goto("/dashboard");

		await expect(page).toHaveURL(/\/sign-in/);
		await expect(page).toHaveURL(/callbackUrl=%2Fdashboard/);
	});

	test("serves public docs without authentication", async ({ request }) => {
		const redirect = await request.get("/docs", { maxRedirects: 0 });
		expect([307, 308]).toContain(redirect.status());
		expect(redirect.headers().location).toBe("/docs/index.html");

		const landing = await request.get("/docs/index.html");
		expect(landing.ok()).toBe(true);
		await expect(landing.text()).resolves.toContain(
			"Terminal-first control for your code portfolio.",
		);
	});

	test("rejects unauthenticated workspace sync writes", async ({ request }) => {
		const response = await request.post("/api/workspaces/sync", {
			data: { workspaces: [] },
			maxRedirects: 0,
		});

		expect(response.status()).toBe(401);
	});
});
