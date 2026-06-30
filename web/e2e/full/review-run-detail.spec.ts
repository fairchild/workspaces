import { expect, type Page, test } from "@playwright/test";

const REVIEW_RUN_FINGERPRINT = "e2e-review-run-projected";

async function expectReviewRunDetail(page: Page) {
	await expect(
		page.getByRole("heading", { name: "fairchild/workspaces#703" }),
	).toBeVisible();
	await expect(
		page.getByRole("heading", { name: "Published to GitHub" }),
	).toBeVisible();
	await expect(
		page.getByRole("heading", { name: "Where this run is going" }),
	).toBeVisible();
	await expect(
		page.getByLabel("Managed review lifecycle").getByRole("listitem"),
	).toHaveCount(6);
	await expect(page.getByRole("heading", { name: "Run path" })).toBeVisible();
	await expect(
		page.getByRole("heading", { name: "Projection ledger" }),
	).toBeVisible();
	await expect(page.getByText("Commit status")).toBeVisible();
	await expect(
		page.locator("details").filter({ hasText: "Operator details" }),
	).toBeVisible();
}

test.describe("Managed review run detail", () => {
	test("renders the phase-oriented run progression", async ({ page }) => {
		await page.setViewportSize({ width: 1440, height: 1000 });
		await page.goto(`/dashboard/review-runs/${REVIEW_RUN_FINGERPRINT}`);

		await expectReviewRunDetail(page);
	});

	test("keeps the progression readable on mobile", async ({ page }) => {
		await page.setViewportSize({ width: 390, height: 900 });
		await page.goto(`/dashboard/review-runs/${REVIEW_RUN_FINGERPRINT}`);

		await expectReviewRunDetail(page);
		const overflow = await page.evaluate(
			() => document.documentElement.scrollWidth - window.innerWidth,
		);
		expect(overflow).toBeLessThanOrEqual(1);
	});
});
