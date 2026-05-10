import { expect, test } from "@playwright/test";

test.describe("Public docs", () => {
	test("serves /docs without authentication", async ({ page }) => {
		await page.goto("/docs");

		await expect(page).toHaveURL(/\/docs\/index\.html$/);
		await expect(
			page.getByRole("heading", {
				name: "Terminal-first control for your code portfolio.",
			}),
		).toBeVisible();
	});

	test("renders a Markdown document from the landing page", async ({ page }) => {
		await page.goto("/docs");
		await page
			.getByRole("link", { name: /Product Overview/ })
			.first()
			.click();

		await expect(page).toHaveURL(/\/docs\/product_overview$/);
		await expect(
			page.getByRole("heading", { name: "WorkSpaces — Product Overview" }),
		).toBeVisible();
		await expect(page.getByText("Repository").first()).toBeVisible();
	});

	test("filters related docs from concept chips", async ({ page }) => {
		await page.goto("/docs/product_overview");

		await page.getByRole("button", { name: "Repository" }).click();

		await expect(page.getByRole("heading", { name: "Related Docs" })).toBeVisible();
		await expect(page.locator("#related-heading")).toHaveText("Repository");
		await expect(
			page.locator("#related-docs").getByRole("link", { name: /Vocabulary/ }),
		).toBeVisible();
	});

	test("shows friendly page metadata before exact details", async ({ page }) => {
		await page.goto("/docs/performance/dashboard");

		await expect(page.locator("#doc-updated")).toContainText("Mar 22, 2026");
		await expect(page.locator("#doc-updated")).not.toContainText(
			"2026-03-22T10:29:08-0700",
		);
		await expect(page.locator("#content")).not.toContainText("Last updated:");
	});

	test("serves suffixed Markdown docs as raw Markdown", async ({ request }) => {
		const response = await request.get("/docs/product_overview.md");

		expect(response.ok()).toBe(true);
		expect(response.headers()["content-type"]).toContain("text/markdown");
		await expect(response.text()).resolves.toMatch(
			/^# WorkSpaces — Product Overview/,
		);
	});

	test("renders extensionless nested docs paths", async ({ page }) => {
		await page.goto("/docs/development/libghostty-integration");

		await expect(
			page.getByRole("heading", { name: "libghostty Integration Guide" }),
		).toBeVisible();
	});

	test("does not render Markdown outside the curated manifest", async ({ page }) => {
		await page.goto("/docs/design/product_overview");

		await expect(
			page.getByRole("heading", { name: "Document not published" }),
		).toBeVisible();
		await expect(page.getByText("outside the curated native WorkSpaces docs set")).toBeVisible();
	});
});
