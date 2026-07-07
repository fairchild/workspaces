/*
 * Terminal drawer e2e (#752), hermetic over the mock PTY seam: the drawer
 * opens from its quiet affordances (Ctrl+` and the `>_` control), runs the
 * full ticket mint→redeem exchange, paints a shell, and runs a command.
 * Network-level assertion: the ticket travels only in POST bodies — no
 * request URL ever carries it. Videos are recorded as the PR's evidence.
 */
import { expect, type Page, test } from "@playwright/test";

test.use({ video: "on" });

// The drawer + ghostty-web WASM load lazily on first open.
const DRAWER_TIMEOUT = 15_000;

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

function drawer(page: Page) {
	return page.getByTestId("terminal-drawer");
}

async function openDrawerAndAwaitShell(page: Page): Promise<void> {
	await page.keyboard.press("Control+Backquote");
	await expect(drawer(page)).toHaveAttribute("data-open", "true");
	await expect(drawer(page)).toHaveAttribute("data-ready", "true", {
		timeout: DRAWER_TIMEOUT,
	});
	await expect(page.getByTestId("terminal-transcript")).toContainText(
		"mock sandbox shell",
	);
}

test("Ctrl+` opens a live shell and a typed command runs in it", async ({
	page,
}) => {
	// Collect every request URL and the minted ticket, to prove the token
	// never rides in a URL (only in POST bodies).
	const requestUrls: string[] = [];
	page.on("request", (request) => requestUrls.push(request.url()));
	let mintedTicket = "";
	page.on("response", async (response) => {
		if (response.url().endsWith("/terminal") && response.ok()) {
			const body = (await response.json().catch(() => ({}))) as {
				ticket?: string;
			};
			if (body.ticket) mintedTicket = body.ticket;
		}
	});

	await createSession(page);
	await openDrawerAndAwaitShell(page);

	// Type a command into the terminal and see its output land.
	await page.keyboard.type("echo drawer-proof-42");
	await page.keyboard.press("Enter");
	await expect(page.getByTestId("terminal-transcript")).toContainText(
		"drawer-proof-42",
	);
	// The status bar names the transport honestly: this is the mock seam.
	await expect(page.getByTestId("terminal-status")).toContainText("mock PTY");

	// The exchange really ran (a ticket was minted)…
	expect(mintedTicket).not.toBe("");
	// …and no URL — page, API, or asset — ever carried it, nor any ticket=
	// query parameter at all.
	for (const url of requestUrls) {
		expect(url).not.toContain(mintedTicket);
		expect(url).not.toContain("ticket=");
	}
});

test("the drawer closes and reopens from the quiet control, keeping its shell", async ({
	page,
}) => {
	await createSession(page);
	await openDrawerAndAwaitShell(page);
	await page.keyboard.type("echo still-here");
	await page.keyboard.press("Enter");
	await expect(page.getByTestId("terminal-transcript")).toContainText(
		"still-here",
	);

	// Close via Ctrl+`; the drawer hides but is not torn down.
	await page.keyboard.press("Control+Backquote");
	await expect(drawer(page)).toHaveAttribute("data-open", "false");

	// Reopen from the `>_` control: same shell, scrollback intact, no
	// second banner (the transport connected exactly once).
	await page.getByTestId("terminal-toggle").click();
	await expect(drawer(page)).toHaveAttribute("data-open", "true");
	await expect(page.getByTestId("terminal-transcript")).toContainText(
		"still-here",
	);
	const transcript = await page
		.getByTestId("terminal-transcript")
		.textContent();
	expect(transcript?.match(/mock sandbox shell/g)).toHaveLength(1);
});

test.describe("signed out", () => {
	test.use({ storageState: { cookies: [], origins: [] } });

	test("the terminal routes are bounced before any sandbox work", async ({
		request,
	}) => {
		for (const path of [
			"/api/sessions/any/terminal",
			"/api/sessions/any/terminal/redeem",
		]) {
			const response = await request.post(path, {
				data: {},
				maxRedirects: 0,
			});
			// The edge answers 401 JSON directly, same shape as the route gate (#828).
			expect(response.status()).toBe(401);
			await expect(response.json()).resolves.toEqual({
				error: "not signed in as the allowed user",
			});
		}
	});
});
