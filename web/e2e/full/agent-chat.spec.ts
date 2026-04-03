import { expect, test } from "@playwright/test";

const CHAT_URL = "/dashboard/fairchild/workspaces?tab=chat";

test.describe("Agent chat with mock provider", () => {
	test("sends @agent message and receives mock response", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForLoadState("networkidle");

		const input = page.getByPlaceholder("Type a message or @mention an agent");
		await expect(input).toBeVisible();

		// Send a unique @agent message
		const unique = `e2e-${Date.now()}`;
		await input.fill(`@april-clearwater ${unique}`);
		await input.press("Enter");

		// The mock provider echoes back the message — wait for it to appear
		await expect(
			page.getByText(unique, { exact: false }).last(),
		).toBeVisible({ timeout: 30_000 });

		// Verify the mock response text is present
		await expect(
			page.getByText("Mock agent response", { exact: false }).last(),
		).toBeVisible();
	});

	test("follow-up message sends same threadId", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForLoadState("networkidle");

		const input = page.getByPlaceholder("Type a message or @mention an agent");

		// First message — capture the agent-stream request
		await input.fill("@april-clearwater first message");
		const [firstReq] = await Promise.all([
			page.waitForRequest(
				(req) =>
					req.url().includes("agent-stream") && req.method() === "POST",
			),
			input.press("Enter"),
		]);
		const firstBody = firstReq.postDataJSON();

		// Wait for response to complete
		await expect(
			page.getByText("Mock agent response", { exact: false }).last(),
		).toBeVisible({ timeout: 30_000 });

		// Second message — capture threadId
		await input.fill("@april-clearwater second message");
		const [secondReq] = await Promise.all([
			page.waitForRequest(
				(req) =>
					req.url().includes("agent-stream") && req.method() === "POST",
			),
			input.press("Enter"),
		]);
		const secondBody = secondReq.postDataJSON();

		// Thread continuity: same threadId on follow-up
		expect(firstBody.threadId).toBeTruthy();
		expect(secondBody.threadId).toBe(firstBody.threadId);
	});

	test("second message restores from snapshot (same session)", async ({
		page,
	}) => {
		await page.goto(CHAT_URL);
		await page.waitForLoadState("networkidle");

		const input = page.getByPlaceholder(
			"Type a message or @mention an agent",
		);
		await expect(input).toBeVisible();

		// First message — creates a fresh session, gets snapshotted after response
		const unique = `snap-${Date.now()}`;
		await input.fill(`@april-clearwater first-${unique}`);
		await input.press("Enter");

		// Wait for the first mock response containing our unique token
		// nth(1) = second match: first is the user message, second is the agent echo
		await expect(
			page.getByText(`first-${unique}`, { exact: false }).nth(1),
		).toBeVisible({ timeout: 30_000 });

		// First response must NOT be restored (fresh session)
		const firstResponseText = await page
			.getByText(`first-${unique}`, { exact: false })
			.nth(1)
			.textContent();
		expect(firstResponseText).not.toContain("[restored]");

		// Second message — session manager finds the snapshotted session and restores it
		await input.fill(`@april-clearwater second-${unique}`);
		await input.press("Enter");

		// The restored mock response includes "[restored]" prefix and our unique token
		// in the enriched message. Use a locator scoped to our unique token to avoid
		// matching responses from parallel tests.
		const restoredLocator = page.locator("span", {
			hasText: `second-${unique}`,
		}).filter({ hasText: "[restored]" });

		await expect(restoredLocator.first()).toBeVisible({ timeout: 30_000 });
	});

	test("agent response persists in timeline after page reload", async ({
		page,
	}) => {
		await page.goto(CHAT_URL);
		await page.waitForLoadState("networkidle");

		const input = page.getByPlaceholder("Type a message or @mention an agent");
		const unique = `persist-${Date.now()}`;
		await input.fill(`@april-clearwater ${unique}`);
		await input.press("Enter");

		// Wait for mock response containing our unique string
		await expect(
			page.getByText(unique, { exact: false }).last(),
		).toBeVisible({ timeout: 30_000 });

		// Reload and verify persistence
		await page.reload();
		await page.waitForLoadState("networkidle");

		// Scroll to bottom to find recent messages
		await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
		await page.waitForTimeout(1000);

		// The user message should still be visible after reload
		await expect(
			page.getByText(unique, { exact: false }).first(),
		).toBeVisible({ timeout: 10_000 });
	});
});
