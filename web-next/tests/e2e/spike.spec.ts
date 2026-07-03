/*
 * E2E for the Phase 0 /spike page: sending a message streams a full mock
 * coding turn — prose, tool cards (Read/Edit/Bash) with outputs, and a
 * re-enabled compose when the turn finishes.
 */
import { expect, test } from "@playwright/test";

// The mock turn takes ~5s of scripted delays end to end.
const TURN_TIMEOUT = 20_000;

test("home links to the spike", async ({ page }) => {
	await page.goto("/");
	await expect(page.getByRole("heading", { name: "Spaces" })).toBeVisible();
	await page.getByRole("link", { name: /transcript spike/i }).click();
	await expect(page).toHaveURL(/\/spike$/);
});

test("streams a mock coding turn with tool cards", async ({ page }) => {
	await page.goto("/spike");

	const input = page.getByPlaceholder("Ask the agent to fix something…");
	await input.fill("Fix the failing session test");
	await page.getByRole("button", { name: "send" }).click();

	// The user message renders immediately; the assistant reply streams in.
	await expect(
		page.locator('[data-message-role="user"]'),
	).toContainText("Fix the failing session test");
	await expect(page.locator('[data-message-role="assistant"]')).toContainText(
		"failing test",
		{ timeout: TURN_TIMEOUT },
	);

	// Each scripted tool call renders a card, with its result attached.
	const readCard = page.locator('[data-testid="tool-card"][data-tool="Read"]');
	const editCard = page.locator('[data-testid="tool-card"][data-tool="Edit"]');
	const bashCard = page.locator('[data-testid="tool-card"][data-tool="Bash"]');
	await expect(readCard).toBeVisible({ timeout: TURN_TIMEOUT });
	await expect(readCard).toContainText("src/lib/session.ts", {
		timeout: TURN_TIMEOUT,
	});
	await expect(editCard).toContainText("SessionNotFoundError", {
		timeout: TURN_TIMEOUT,
	});
	await expect(bashCard).toContainText("4 passed", { timeout: TURN_TIMEOUT });

	// Turn completes: closing prose arrives and the compose re-enables.
	await expect(page.locator('[data-message-role="assistant"]')).toContainText(
		"All four tests pass",
		{ timeout: TURN_TIMEOUT },
	);
	await expect(page.getByRole("button", { name: "send" })).toBeEnabled();
});
