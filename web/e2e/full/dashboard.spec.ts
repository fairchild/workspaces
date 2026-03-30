import { test } from "@playwright/test";

// TODO: Set up auth fixture for authenticated tests
// Strategy options:
// 1. Use Playwright's storageState with a pre-authenticated session cookie
// 2. Create a test-only API endpoint that issues a session
// 3. Mock the auth middleware in test mode
// See: https://playwright.dev/docs/auth

test.describe("Dashboard (authenticated)", () => {
	test.skip("shows repo detail after sign-in", async ({ page }) => {
		// TODO: Sign in via auth fixture
		// 1. Navigate to /dashboard
		// 2. Verify sidebar shows repos
		// 3. Click a repo
		// 4. Verify agent overview cards render (agents, skills, PRs, issues)
	});

	test.skip("activity feed shows webhook events with type badges", async ({
		page,
	}) => {
		// TODO: Sign in via auth fixture
		// 1. Navigate to /dashboard/owner/repo
		// 2. Verify activity feed panel is visible on desktop
		// 3. Verify event cards show CI/PR/PUSH/ISSUE badges
	});
});
