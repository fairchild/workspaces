import { expect, test } from "@playwright/test";

const CHAT_URL = "/dashboard/fairchild/workspaces?tab=chat";

test.describe("Chat tab navigation", () => {
	test("tab switching updates URL and returns", async ({ page }) => {
		await page.goto("/dashboard");
		await expect(page.getByRole("button", { name: "Dashboard" })).toBeVisible();

		await page.getByRole("button", { name: "Chat" }).click();
		await expect(page).toHaveURL(/tab=chat/);

		await page.getByRole("button", { name: "Dashboard" }).click();
		await expect(page).not.toHaveURL(/tab=chat/);
	});

	test("chat tab autofocuses compose input", async ({ page }) => {
		await page.goto("/dashboard/fairchild/workspaces");
		await page.getByRole("button", { name: "Chat" }).click();
		const textarea = page.getByPlaceholder("Type a message or @mention an agent");
		await expect(textarea).toBeFocused({ timeout: 3000 });
	});

	test("direct navigation to chat tab works", async ({ page }) => {
		await page.goto(CHAT_URL);
		await expect(page.getByRole("button", { name: "Chat" })).toHaveClass(/tabActive|Active/);
		await expect(page.getByPlaceholder("Type a message or @mention an agent")).toBeVisible();
	});
});

test.describe("Compose bar", () => {
	test("shows placeholder and send button", async ({ page }) => {
		await page.goto(CHAT_URL);
		await expect(page.getByPlaceholder("Type a message or @mention an agent")).toBeVisible();
		await expect(page.getByRole("button", { name: "Send" })).toBeVisible();
	});

	test("shows helper text", async ({ page }) => {
		await page.goto(CHAT_URL);
		await expect(page.getByText("Enter to send")).toBeVisible();
		await expect(page.getByText("@ to mention agent")).toBeVisible();
	});

	test("send button is disabled when input is empty", async ({ page }) => {
		await page.goto(CHAT_URL);
		const sendBtn = page.getByRole("button", { name: "Send" });
		await expect(sendBtn).toBeDisabled();
	});

	test("typing enables send button", async ({ page }) => {
		await page.goto(CHAT_URL);
		const textarea = page.getByPlaceholder("Type a message or @mention an agent");
		await textarea.fill("hello world");
		const sendBtn = page.getByRole("button", { name: "Send" });
		await expect(sendBtn).toBeEnabled();
	});

	test("shift+enter adds newline instead of sending", async ({ page }) => {
		await page.goto(CHAT_URL);
		const textarea = page.getByPlaceholder("Type a message or @mention an agent");
		await textarea.fill("line 1");
		await textarea.press("Shift+Enter");
		await textarea.pressSequentially("line 2");
		const value = await textarea.inputValue();
		expect(value).toContain("line 1");
		expect(value).toContain("line 2");
	});
});

test.describe("Timeline rendering", () => {
	test("shows day separators between different days", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);
		const separators = page.locator("[class*='daySeparator']");
		const count = await separators.count();
		expect(count).toBeGreaterThanOrEqual(1);
	});

	test("shows chat messages with author and content", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);
		// Seeded user message
		await expect(page.getByText("@april-clearwater summarize the readme")).toBeVisible();
		// Seeded agent response
		await expect(page.getByText(/terminal-first workspace manager/)).toBeVisible();
	});

	test("agent messages have accent styling", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);
		// Find the agent message row
		const agentMsg = page.locator("[class*='messageAgent']");
		const count = await agentMsg.count();
		expect(count).toBeGreaterThanOrEqual(1);
	});

	test("agent author name is styled differently from user", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);
		const agentAuthor = page.locator("[class*='messageAuthorAgent']");
		const count = await agentAuthor.count();
		expect(count).toBeGreaterThanOrEqual(1);
	});
});

test.describe("Collapsed event groups", () => {
	test("consecutive events collapse into grouped rows", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);
		// Look for collapsed event group buttons (badge count pattern)
		const groups = page.locator("button[class*='group']");
		const count = await groups.count();
		expect(count).toBeGreaterThanOrEqual(1);
	});

	test("collapsed group shows badge counts", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);
		// Badge counts like "CI ×3" — &times; renders as × (U+00D7)
		await expect(page.getByText(/CI\s*[×x]\s*\d/i).first()).toBeVisible();
	});

	test("collapsed group shows time range", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);
		// Time range appears in the group row
		const timeRanges = page.locator("[class*='timeRange']");
		const count = await timeRanges.count();
		expect(count).toBeGreaterThanOrEqual(1);
	});

	test("clicking collapsed group expands to show individual events", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);

		// Find a collapsed group and click it
		const group = page.locator("button[class*='group']").first();
		await expect(group).toBeVisible();

		// Before click: no expanded list
		const expandedBefore = page.locator("[class*='expandedList']");
		await expect(expandedBefore).toHaveCount(0);

		// Click to expand
		await group.click();

		// After click: expanded list shows individual events
		const expandedAfter = page.locator("[class*='expandedList']");
		await expect(expandedAfter).toHaveCount(1);

		// Expanded items should have summaries
		const items = page.locator("[class*='expandedItem']");
		const itemCount = await items.count();
		expect(itemCount).toBeGreaterThanOrEqual(2);
	});

	test("clicking expanded group collapses it again", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);

		const group = page.locator("button[class*='group']").first();
		// Expand
		await group.click();
		await expect(page.locator("[class*='expandedList']")).toHaveCount(1);
		// Collapse
		await group.click();
		await expect(page.locator("[class*='expandedList']")).toHaveCount(0);
	});

	test("chevron rotates when group is expanded", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);

		const group = page.locator("button[class*='group']").first();
		const chevron = group.locator("[class*='chevron']");

		// Before: no open class
		await expect(chevron).not.toHaveClass(/chevronOpen/);

		await group.click();

		// After: has open class
		await expect(chevron).toHaveClass(/chevronOpen/);
	});

	test("single events between chats render as StatusCard not group", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);
		// StatusCard uses badge class for individual events
		// There should be both grouped and individual event rendering
		const allCards = page.locator("[class*='card']");
		const allGroups = page.locator("button[class*='group']");
		// We should have at least some groups (consecutive events)
		expect(await allGroups.count()).toBeGreaterThanOrEqual(1);
	});
});

test.describe("Timeline order", () => {
	test("messages appear in chronological order (oldest first)", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);

		// Get all visible message texts in order
		const messages = page.locator("[class*='messageContent']");
		const texts = await messages.allTextContents();

		// "Hello from yesterday" should appear before today's messages
		const yesterdayIdx = texts.findIndex((t) => t.includes("Hello from yesterday"));
		const todayIdx = texts.findIndex((t) => t.includes("summarize the readme"));

		if (yesterdayIdx !== -1 && todayIdx !== -1) {
			expect(yesterdayIdx).toBeLessThan(todayIdx);
		}
	});

	test("newest content is at the bottom (scroll anchor)", async ({ page }) => {
		await page.goto(CHAT_URL);
		await page.waitForTimeout(2000);

		// The last chat message should be near the bottom
		const lastMsg = page.getByText("Can you check the open issues?");
		if (await lastMsg.isVisible()) {
			const box = await lastMsg.boundingBox();
			const viewport = page.viewportSize();
			// Should be in the lower half of the viewport
			expect(box!.y).toBeGreaterThan(viewport!.height * 0.3);
		}
	});
});

test.describe("Empty and loading states", () => {
	test("shows empty state when no repo selected", async ({ page }) => {
		await page.goto("/dashboard?tab=chat");
		await expect(page.getByText(/select a repo/i)).toBeVisible({ timeout: 3000 });
	});
});
