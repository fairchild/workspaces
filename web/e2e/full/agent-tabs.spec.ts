import { expect, test } from "@playwright/test";

const DASHBOARD_URL = "/dashboard/fairchild/workspaces";
const CHAT_URL = `${DASHBOARD_URL}?tab=chat`;

test.describe("Main tab bar", () => {
	test("offers Dashboard and Chat, with no Terminal tab", async ({ page }) => {
		await page.goto(DASHBOARD_URL);
		const tabBar = page.locator("nav").first();
		await expect(tabBar.getByRole("button", { name: "Dashboard" })).toBeVisible();
		await expect(tabBar.getByRole("button", { name: "Chat" })).toBeVisible();
		await expect(page.getByRole("button", { name: "Terminal" })).toHaveCount(0);
	});

	test("a stale ?tab=terminal&agent= link lands on Dashboard with both params dropped", async ({
		page,
	}) => {
		await page.goto(`${DASHBOARD_URL}?tab=terminal&agent=shell`);
		await expect(page).not.toHaveURL(/tab=|agent=/);
		await expect(
			page.locator("nav").first().getByRole("button", { name: "Dashboard" }),
		).toHaveClass(/tabActive|Active/);
	});
});

test.describe("Chat agent sub-tabs", () => {
	test("chat tab shows agent sub-tabs and includes 'all'", async ({ page }) => {
		await page.goto(CHAT_URL);
		const subTabBar = page.locator("nav").nth(1);
		await expect(
			subTabBar.getByRole("button", { name: /^all$/ }),
		).toBeVisible();
		await expect(
			subTabBar.getByRole("button", {
				name: /april-clearwater|April Clearwater/,
			}),
		).toBeVisible({ timeout: 15_000 });
	});

	test("clicking a sub-tab updates the ?agent= URL param", async ({ page }) => {
		await page.goto(CHAT_URL);
		const subTabBar = page.locator("nav").nth(1);
		await subTabBar
			.getByRole("button", { name: /april-clearwater|April Clearwater/ })
			.click();
		await expect(page).toHaveURL(/agent=april-clearwater/);
	});

	test("chat 'all' sub-tab clears the agent URL param", async ({ page }) => {
		await page.goto(`${CHAT_URL}&agent=april-clearwater`);
		const subTabBar = page.locator("nav").nth(1);
		await subTabBar.getByRole("button", { name: /^all$/ }).click();
		await expect(page).not.toHaveURL(/agent=/);
	});
});
