import { expect, test } from "@playwright/test";

test.describe("Dashboard (authenticated)", () => {
	test("loads dashboard page with tab bar", async ({ page }) => {
		await page.goto("/dashboard");
		await expect(page.getByRole("button", { name: "Dashboard" })).toBeVisible();
		await expect(page.getByRole("button", { name: "Chat" })).toBeVisible();
	});

	test("shows sidebar with Add repos button", async ({ page }) => {
		await page.goto("/dashboard");
		await expect(page.getByText("Add repos")).toBeVisible();
	});

	test.skip("shows repo detail after selecting a repo", async ({ page }) => {
		// TODO: Needs seeded repos in the database
		// 1. Navigate to /dashboard
		// 2. Click a repo in sidebar
		// 3. Verify agent overview cards render (agents, skills, PRs, issues)
	});

	test.skip("activity feed shows webhook events with type badges", async ({
		page,
	}) => {
		// TODO: Needs seeded webhook events in the database
		// 1. Navigate to /dashboard/owner/repo
		// 2. Verify activity feed panel is visible on desktop
		// 3. Verify event cards show CI/PR/PUSH/ISSUE badges
	});
});
