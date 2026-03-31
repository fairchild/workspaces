import { expect, test } from "@playwright/test";

test.describe("Dashboard (authenticated)", () => {
	test("loads dashboard page with tab bar", async ({ page }) => {
		await page.goto("/dashboard");
		await expect(page.getByRole("button", { name: "Dashboard" })).toBeVisible();
		await expect(page.getByRole("button", { name: "Chat" })).toBeVisible();
	});

	test("shows sidebar with seeded repo", async ({ page }) => {
		await page.goto("/dashboard");
		await expect(page.getByText("workspaces")).toBeVisible();
	});

	test("navigates to repo detail", async ({ page }) => {
		await page.goto("/dashboard/fairchild/workspaces");
		await expect(page.getByText("fairchild/workspaces")).toBeVisible();
	});

	test.skip("activity feed shows webhook events with type badges", async ({
		page,
	}) => {
		// TODO: Activity feed polls /api/events which requires agent discovery
		// via GitHub API. Seeded DB events exist but the component needs
		// the full agent/repo context to render correctly.
	});
});
