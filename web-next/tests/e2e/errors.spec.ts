/*
 * First-class error surfaces + lifecycle controls (#753), hermetic over the
 * mock provider's injection seams: each failure class — provisioning, sandbox
 * died mid-turn, stream error — renders its own calm inline card (no toast
 * chrome), the stop control ends a streaming turn and releases the session
 * for the next send, and the masthead reports the sandbox state truthfully
 * (a mock session never has one: "no sandbox", and no stop-sandbox control).
 */
import { expect, type Page, test } from "@playwright/test";

// The mock turn takes ~9s of scripted delays end to end.
const TURN_TIMEOUT = 20_000;

async function createSession(page: Page): Promise<void> {
	await page.goto("/");
	const picker = page.getByTestId("new-session-picker");
	if (!(await picker.isVisible())) {
		await page.getByRole("button", { name: "+ new session" }).click();
	}
	await page
		.getByRole("textbox", { name: "Repository (owner/name)" })
		.fill("fairchild/workspaces");
	await page.keyboard.press("Enter");
	await expect(page).toHaveURL(/\/sessions\/[0-9a-f-]{36}$/);
}

async function send(page: Page, text: string): Promise<void> {
	await page.getByRole("textbox", { name: "Reply to Claude" }).fill(text);
	await page.keyboard.press("Enter");
}

test("a provisioning failure renders its calm card — the failure is the whole reply", async ({
	page,
}) => {
	await createSession(page);
	await send(page, "Build the thing __mock_provision_error__");

	// The user's message is never at risk; the activity line breathes while
	// the mock "provisions"…
	await expect(page.locator('[data-message-role="user"]')).toContainText(
		"Build the thing",
	);

	// …then the sandbox never comes up: the failure card is the entire
	// assistant reply (no content ever streamed), with Retry on offer.
	await expect(page.getByTestId("turn-failure")).toContainText(
		"Sandbox provisioning failed",
		{ timeout: TURN_TIMEOUT },
	);
	await expect(page.getByRole("button", { name: "Retry" })).toBeVisible();
	await expect(page.getByTestId("activity-line")).toHaveCount(0);
	await expect(page.getByRole("button", { name: "Send" })).toBeEnabled();
});

test("a sandbox that dies mid-turn keeps the streamed work above its failure card", async ({
	page,
}) => {
	await createSession(page);
	await send(page, "Fix the flaky test __mock_sandbox_died__");

	await expect(page.getByTestId("turn-failure")).toContainText(
		"The sandbox died mid-turn",
		{ timeout: TURN_TIMEOUT },
	);
	// The prose and the tool call that landed before the VM died are still
	// there — the failure is recorded after the work, not instead of it.
	await expect(page.locator('[data-message-role="assistant"]')).toContainText(
		"Let me reproduce the failure first",
	);
	await expect(page.getByTestId("tool-row")).toHaveCount(1);
	await expect(page.getByRole("button", { name: "Retry" })).toBeVisible();
	await expect(page.getByRole("button", { name: "Send" })).toBeEnabled();
});

test("a stream error surfaces the provider's own error text, live and after reload", async ({
	page,
}) => {
	await createSession(page);
	await send(page, "Refactor the adapter __mock_stream_error__");

	await expect(page.getByTestId("turn-failure")).toContainText(
		"The stream broke before the turn finished",
		{ timeout: TURN_TIMEOUT },
	);
	await expect(page.getByRole("button", { name: "Send" })).toBeEnabled();

	// The projection tags the same failure from the persisted error chunk —
	// live and reloaded agree.
	await page.reload();
	await expect(page.getByTestId("turn-failure")).toContainText(
		"The stream broke before the turn finished",
	);
	await expect(page.getByRole("button", { name: "Retry" })).toBeVisible();
});

test("stop ends a streaming turn, records it honestly, and releases the session", async ({
	page,
}) => {
	await createSession(page);
	await send(page, "Fix the failing session test");

	// While the turn runs, the send affordance is the stop control.
	const stop = page.getByRole("button", { name: "Stop" });
	await expect(stop).toBeVisible();
	await expect(page.getByTestId("activity-line")).toBeVisible();
	await stop.click();

	// The turn closes as a calm failure card — "Turn stopped." — and compose
	// hands back the send affordance.
	await expect(page.getByTestId("turn-failure")).toContainText("Turn stopped.", {
		timeout: TURN_TIMEOUT,
	});
	await expect(page.getByTestId("activity-line")).toHaveCount(0);
	await expect(page.getByRole("button", { name: "Send" })).toBeEnabled();

	// The session is genuinely released (#811's one-turn-at-a-time guard sees
	// the stopped turn as closed): a follow-up send streams to completion.
	await send(page, "Carry on from where you stopped");
	await expect(page.locator('[data-message-role="user"]')).toHaveCount(2);
	await expect(page.getByTestId("turn-stats")).toBeVisible({
		timeout: TURN_TIMEOUT,
	});

	// The stopped turn's own record survives the later turn, and a reload
	// projects the same story from the log.
	await expect(page.getByTestId("turn-failure")).toContainText("Turn stopped.");
	await page.reload();
	await expect(page.getByTestId("turn-failure")).toContainText("Turn stopped.");
	await expect(page.getByTestId("turn-stats")).toBeVisible();
});

test("the masthead reports the sandbox state truthfully: a mock session has none", async ({
	page,
}) => {
	await createSession(page);
	// The verdict is fetched, not guessed: "no sandbox", with no stop control
	// (there is nothing to stop — a fake button would be dishonest chrome).
	await expect(page.getByTestId("sandbox-state")).toContainText("no sandbox");
	await expect(page.getByTestId("sandbox-stop")).toHaveCount(0);
	await expect(page.getByTestId("open-session-pr")).toHaveCount(0);

	// Still true after a turn: the mock provider parks no sandbox.
	await send(page, "Fix the failing session test");
	await expect(page.getByTestId("turn-stats")).toBeVisible({
		timeout: TURN_TIMEOUT,
	});
	await expect(page.getByTestId("sandbox-state")).toContainText("no sandbox");
	await expect(page.getByTestId("open-session-pr")).toHaveCount(0);
});
