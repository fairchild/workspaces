/*
 * Terminal drawer e2e (#752), hermetic over the mock PTY seam: the drawer
 * opens from its quiet affordances (Ctrl+` and the `>_` control), loads the
 * libghostty-vt wasm on first open and not before, runs the full ticket
 * mint→redeem exchange, paints a shell on its canvas, and runs a command.
 * Network-level assertion: the ticket travels only in POST bodies — no
 * request URL ever carries it. Videos are recorded as the PR's evidence.
 */
import { expect, type Page, test } from "@playwright/test";

test.use({ video: "on" });

// The terminal binding and its wasm load lazily on first open.
const DRAWER_TIMEOUT = 15_000;
const WASM_PATH = /\/ghostty-vt\/ghostty-vt-[\d.]+-small\.wasm$/;

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

/** CanvasTerminal's screen-reader mirror of the viewport: what the canvas shows, as text. */
function screen(page: Page) {
	return drawer(page).getByRole("document", { name: "Terminal screen" });
}

async function openDrawerAndAwaitShell(page: Page): Promise<void> {
	await page.keyboard.press("Control+Backquote");
	await expect(drawer(page)).toHaveAttribute("data-open", "true");
	await expect(drawer(page)).toHaveAttribute("data-ready", "true", {
		timeout: DRAWER_TIMEOUT,
	});
	await expect(screen(page)).toContainText("mock sandbox shell");
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
	await expect(screen(page)).toContainText("drawer-proof-42");
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
	await expect(screen(page)).toContainText("still-here");

	// Close via Ctrl+`; the drawer hides but is not torn down.
	await page.keyboard.press("Control+Backquote");
	await expect(drawer(page)).toHaveAttribute("data-open", "false");

	// Reopen from the `>_` control: same shell, scrollback intact, no
	// second banner (the transport connected exactly once).
	await page.getByTestId("terminal-toggle").click();
	await expect(drawer(page)).toHaveAttribute("data-open", "true");
	await expect(screen(page)).toContainText("still-here");
	const text = await screen(page).textContent();
	expect(text?.match(/mock sandbox shell/g)).toHaveLength(1);
});

test("the wasm loads on first open, once, same-origin and immutable", async ({
	page,
}) => {
	const wasm: { url: string; status: number; cacheControl: string }[] = [];
	page.on("response", (response) => {
		if (WASM_PATH.test(new URL(response.url()).pathname)) {
			wasm.push({
				url: response.url(),
				status: response.status(),
				cacheControl: response.headers()["cache-control"] ?? "",
			});
		}
	});

	await createSession(page);
	await page.waitForLoadState("networkidle");
	expect(wasm).toEqual([]);

	await openDrawerAndAwaitShell(page);
	await expect(drawer(page).getByTestId("terminal-host").locator("canvas")).toBeVisible();
	expect(wasm).toHaveLength(1);
	expect(new URL(wasm[0].url).origin).toBe(new URL(page.url()).origin);
	expect(wasm[0].status).toBe(200);
	expect(wasm[0].cacheControl).toContain("immutable");

	// Closing and reopening reuses the terminal; nothing is fetched again.
	await page.keyboard.press("Control+Backquote");
	await page.keyboard.press("Control+Backquote");
	await expect(drawer(page)).toHaveAttribute("data-open", "true");
	expect(wasm).toHaveLength(1);
});

test("a session with no live sandbox gets the calm note, not a shell", async ({
	page,
}) => {
	await page.route("**/api/sessions/*/terminal", (route) =>
		route.fulfill({
			json: { state: "no-sandbox", reason: "sandbox stopped" },
		}),
	);
	await createSession(page);
	await page.keyboard.press("Control+Backquote");
	const empty = page.getByTestId("terminal-empty");
	await expect(empty).toContainText("No live sandbox.");
	await expect(empty).toContainText("sandbox stopped");
	await expect(page.getByTestId("terminal-status")).toContainText("no live sandbox");
	await expect(drawer(page).getByRole("button", { name: "check again" })).toBeVisible();
	await expect(drawer(page)).toHaveAttribute("data-ready", "false");
});

test("a wasm that fails to load says so, and try again recovers", async ({
	page,
}) => {
	await page.route(WASM_PATH, (route) => route.fulfill({ status: 404, body: "" }));
	await createSession(page);
	await page.keyboard.press("Control+Backquote");
	await expect(page.getByTestId("terminal-status")).toContainText("failed to load");
	await expect(page.getByTestId("terminal-empty")).toContainText("Terminal unavailable.");
	await expect(page.getByTestId("terminal-empty")).toContainText("HTTP 404");

	await page.unroute(WASM_PATH);
	await drawer(page).getByRole("button", { name: "try again" }).click();
	await expect(drawer(page)).toHaveAttribute("data-ready", "true", {
		timeout: DRAWER_TIMEOUT,
	});
	await expect(screen(page)).toContainText("mock sandbox shell");
	await expect(page.getByTestId("terminal-empty")).toHaveCount(0);
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
