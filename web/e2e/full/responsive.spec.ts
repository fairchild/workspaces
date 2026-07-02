import { expect, test } from "@playwright/test";

const MOBILE = { width: 375, height: 667 };
const DESKTOP = { width: 1280, height: 800 };

test.describe("Responsive layout (authenticated)", () => {
	test("mobile: sidebar reachable via hamburger drawer, Escape closes", async ({
		page,
	}) => {
		await page.setViewportSize(MOBILE);
		await page.goto("/dashboard");

		const hamburger = page.getByRole("button", { name: "Open repositories" });
		await expect(hamburger).toBeVisible();
		await expect(hamburger).toHaveAttribute("aria-expanded", "false");

		await hamburger.click();

		const drawer = page.getByRole("dialog", { name: "Repositories" });
		await expect(drawer).toBeVisible();
		await expect(drawer.getByText("workspaces")).toBeVisible();
		await expect(hamburger).toHaveAttribute("aria-expanded", "true");

		await page.keyboard.press("Escape");
		await expect(drawer).toBeHidden();
		await expect(hamburger).toHaveAttribute("aria-expanded", "false");
	});

	test("mobile: activity feed reachable via toggle, backdrop closes", async ({
		page,
	}) => {
		await page.setViewportSize(MOBILE);
		await page.goto("/dashboard");

		const toggle = page.getByRole("button", { name: "Open activity feed" });
		await expect(toggle).toBeVisible();

		await toggle.click();

		const feed = page.getByRole("dialog", { name: "Activity feed" });
		await expect(feed).toBeVisible();
		await expect(feed.getByText("Activity", { exact: true })).toBeVisible();

		// The backdrop (labelled "Close") dismisses the drawer. The right-side
		// panel covers most of the width, so click the exposed left strip.
		await page.getByRole("button", { name: "Close" }).click({
			position: { x: 8, y: 320 },
		});
		await expect(feed).toBeHidden();
	});

	test("mobile: no horizontal scroll at 375px", async ({ page }) => {
		await page.setViewportSize(MOBILE);
		await page.goto("/dashboard");
		const overflow = await page.evaluate(
			() =>
				document.documentElement.scrollWidth -
				document.documentElement.clientWidth,
		);
		expect(overflow).toBeLessThanOrEqual(0);
	});

	test("desktop: classic three-column layout intact", async ({ page }) => {
		await page.setViewportSize(DESKTOP);
		await page.goto("/dashboard");

		// Sidebar is inline (first <aside>), not behind a drawer.
		await expect(
			page.locator("aside").first().getByText("workspaces"),
		).toBeVisible();

		// The narrow-viewport affordances are hidden on desktop.
		await expect(
			page.getByRole("button", { name: "Open repositories" }),
		).toBeHidden();
		await expect(
			page.getByRole("button", { name: "Open activity feed" }),
		).toBeHidden();
	});
});
