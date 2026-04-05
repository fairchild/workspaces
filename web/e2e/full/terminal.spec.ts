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
			page.getByRole("button", { name: "Terminal" }),
		).toHaveClass(/tabActive|Active/);
	});

	test("tab switching round-trip preserves state", async ({ page }) => {
		await page.goto(TERMINAL_URL);
		await expect(page).toHaveURL(/tab=terminal/);

		await page.getByRole("button", { name: "Dashboard" }).click();
		await expect(page).not.toHaveURL(/tab=terminal/);

		await page.getByRole("button", { name: "Terminal" }).click();
		await expect(page).toHaveURL(/tab=terminal/);
	});

	test("Cmd+3 switches to Terminal tab", async ({ page }) => {
		await page.goto(DASHBOARD_URL);
		await page.keyboard.press("Meta+3");
		await expect(page).toHaveURL(/tab=terminal/);
	});
});

test.describe("Terminal tab empty states", () => {
	test("shows no-session message when no sandbox active", async ({ page }) => {
		await page.goto(TERMINAL_URL);
		await expect(
			page.getByText("No active sandbox session"),
		).toBeVisible();
	});

	test("shows select-repo message when no repo selected", async ({
		page,
	}) => {
		await page.goto("/dashboard?tab=terminal");
		await expect(
			page.getByText("Select a repository"),
		).toBeVisible();
	});
});
