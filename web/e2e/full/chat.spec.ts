import { test } from "@playwright/test";

// TODO: Set up auth fixture for authenticated tests
// See e2e/full/dashboard.spec.ts for strategy options

test.describe("Chat (authenticated)", () => {
	test.skip("tab switching updates URL", async ({ page }) => {
		// TODO: Sign in via auth fixture
		// 1. Navigate to /dashboard/owner/repo
		// 2. Verify Dashboard tab is active
		// 3. Click Chat tab
		// 4. Verify URL contains ?tab=chat
		// 5. Verify Chat tab has active styling
		// 6. Click Dashboard tab
		// 7. Verify URL no longer contains ?tab=chat
	});

	test.skip("sticky tab bar stays visible while scrolling", async ({
		page,
	}) => {
		// TODO: Sign in via auth fixture
		// 1. Navigate to chat tab with long timeline
		// 2. Scroll down significantly
		// 3. Verify tab bar is still visible (position: sticky)
	});

	test.skip("timeline shows day separators", async ({ page }) => {
		// TODO: Sign in via auth fixture
		// 1. Navigate to chat tab with messages spanning multiple days
		// 2. Verify .daySeparator elements exist
		// 3. Verify separator text matches "Mon DD" format
	});

	test.skip("compose bar @ mention triggers autocomplete", async ({
		page,
	}) => {
		// TODO: Sign in via auth fixture
		// 1. Navigate to chat tab
		// 2. Click compose bar textarea
		// 3. Type "@"
		// 4. Verify autocomplete dropdown appears with agent names
		// 5. Type partial agent name to filter
		// 6. Select an agent
		// 7. Verify agent chip appears and text is updated
	});
});
