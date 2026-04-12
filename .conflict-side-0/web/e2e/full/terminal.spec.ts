import { expect, test } from "@playwright/test";

const DASHBOARD_URL = "/dashboard/fairchild/workspaces";
const TERMINAL_URL = "/dashboard/fairchild/workspaces?tab=terminal";

test.describe("Terminal tab navigation", () => {
	test("tab bar shows Terminal tab", async ({ page }) => {
		await page.goto(DASHBOARD_URL);
		await expect(page.getByRole("button", { name: "Terminal" })).toBeVisible();
	});

	test("clicking Terminal tab updates URL", async ({ page }) => {
		await page.goto(DASHBOARD_URL);
		await page.getByRole("button", { name: "Terminal" }).click();
		await expect(page).toHaveURL(/tab=terminal/);
	});

	test("direct navigation to terminal tab works", async ({ page }) => {
		await page.goto(TERMINAL_URL);
		await expect(
			page.locator("nav").getByRole("button", { name: "Terminal" }),
		).toHaveClass(/tabActive|Active/);
	});

	test("tab switching round-trip preserves state", async ({ page }) => {
		await page.goto(TERMINAL_URL);
		await expect(page).toHaveURL(/tab=terminal/);

		// Wait for the auto-select effect to settle. With a paused session
		// in the seed, the URL gets `&agent=april-clearwater` appended after
		// the first sessions fetch. Click events that fire mid-transition
		// can lose to the URL update; wait for it to stabilize first.
		await expect(page).toHaveURL(/agent=/);

		// Use the first nav explicitly — the second nav is the agent
		// sub-tab strip and doesn't have Dashboard/Terminal buttons.
		const tabBar = page.locator("nav").first();
		await tabBar.getByRole("button", { name: "Dashboard" }).click();
		await expect(page).not.toHaveURL(/tab=terminal/);

		await tabBar.getByRole("button", { name: "Terminal" }).click();
		await expect(page).toHaveURL(/tab=terminal/);
	});

	test("Cmd+3 switches to Terminal tab", async ({ page }) => {
		await page.goto(DASHBOARD_URL);
		await page.keyboard.press("Meta+3");
		await expect(page).toHaveURL(/tab=terminal/);
	});
});

test.describe("Terminal tab empty states", () => {
	test("shows start button when no sandbox active for selected agent", async ({
		page,
	}) => {
		// Seed has a paused april session — auto-select picks it. Navigate
		// directly to a non-existent agent so the empty state is shown.
		await page.goto(`${TERMINAL_URL}&agent=does-not-exist`);
		await expect(page.getByText(/No active terminal/)).toBeVisible();
		await expect(
			page.getByRole("button", { name: /Start terminal/ }),
		).toBeVisible();
	});

	test("shows select-repo message when no repo selected", async ({ page }) => {
		await page.goto("/dashboard?tab=terminal");
		await expect(page.getByText("Select a repository")).toBeVisible();
	});
});

test.describe("Terminal multi-agent sub-tabs", () => {
	test("paused session from seed appears as sub-tab with Resume button", async ({
		page,
	}) => {
		await page.goto(TERMINAL_URL);
		// The seed creates a paused april-clearwater session. The sub-tab
		// strip should show it and the panel should render the Resume state.
		const subTabBar = page.locator("nav").nth(1);
		await expect(
			subTabBar.getByRole("button", { name: /april-clearwater/ }),
		).toBeVisible();
		await expect(
			page.getByText(/sandbox is paused/),
		).toBeVisible();
		await expect(
			page.getByRole("button", { name: /^Resume$/ }),
		).toBeVisible();
	});

	test("clicking sub-tab updates ?agent= URL param", async ({ page }) => {
		await page.goto(TERMINAL_URL);
		const subTabBar = page.locator("nav").nth(1);
		await subTabBar
			.getByRole("button", { name: /april-clearwater/ })
			.click();
		await expect(page).toHaveURL(/agent=april-clearwater/);
	});

	test("agent param persists across Terminal → Chat tab switch", async ({
		page,
	}) => {
		await page.goto(`${TERMINAL_URL}&agent=april-clearwater`);
		const tabBar = page.locator("nav").first();
		await tabBar.getByRole("button", { name: "Chat" }).click();
		await expect(page).toHaveURL(/tab=chat&agent=april-clearwater/);
	});

	test("chat tab shows agent sub-tabs and includes 'all'", async ({
		page,
	}) => {
		await page.goto("/dashboard/fairchild/workspaces?tab=chat");
		const subTabBar = page.locator("nav").nth(1);
		await expect(
			subTabBar.getByRole("button", { name: /^all$/ }),
		).toBeVisible();
		// Even with no terminal session for april active, the chat sub-tabs
		// build from message authors AND terminal sessions, so the seeded
		// paused april session should still produce a sub-tab.
		await expect(
			subTabBar.getByRole("button", { name: /april-clearwater|April Clearwater/ }),
		).toBeVisible();
	});

	test("chat 'all' sub-tab clears the agent URL param", async ({ page }) => {
		await page.goto(
			"/dashboard/fairchild/workspaces?tab=chat&agent=april-clearwater",
		);
		const subTabBar = page.locator("nav").nth(1);
		await subTabBar.getByRole("button", { name: /^all$/ }).click();
		await expect(page).not.toHaveURL(/agent=/);
	});
});
