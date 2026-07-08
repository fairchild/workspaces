/*
 * Sessions home + new-session flow + the live session surface, as one serial
 * story over a database this file owns: it wipes the session/repo rows up
 * front (the e2e server keeps running between local runs), then walks
 * empty state → create via typed owner/name → empty session surface →
 * populated home → create via repo picker → a streamed mock turn →
 * reload-persistence (post-turn and mid-turn).
 */
import { createClient } from "@libsql/client";
import { mkdir, open, rm } from "node:fs/promises";
import path from "node:path";
import { expect, type Page, test } from "@playwright/test";

// Serial: these tests narrate one stateful flow over the shared e2e DB.
test.describe.configure({ mode: "serial" });

const SESSION_URL = /\/sessions\/[0-9a-f-]{36}$/;

// The mock turn takes ~9s of scripted delays end to end.
const TURN_TIMEOUT = 20_000;
const SESSIONS_SPEC_LOCK = path.resolve(
	__dirname,
	"../../.data/sessions-spec.lock",
);
const SESSIONS_SPEC_LOCK_TIMEOUT = 10 * 60_000;

let releaseSessionsSpecLock: (() => Promise<void>) | undefined;

function isSqliteBusy(error: unknown): boolean {
	if (!(error instanceof Error)) return false;
	const code = "code" in error ? error.code : undefined;
	return error.message.includes("SQLITE_BUSY") || code === "SQLITE_BUSY";
}

function isFileExists(error: unknown): boolean {
	return (
		error instanceof Error &&
		"code" in error &&
		error.code === "EEXIST"
	);
}

async function sleep(ms: number): Promise<void> {
	await new Promise((resolve) => setTimeout(resolve, ms));
}

async function acquireSessionsSpecLock(): Promise<() => Promise<void>> {
	await mkdir(path.dirname(SESSIONS_SPEC_LOCK), { recursive: true });
	const deadline = Date.now() + SESSIONS_SPEC_LOCK_TIMEOUT;
	while (true) {
		try {
			const file = await open(SESSIONS_SPEC_LOCK, "wx");
			await file.writeFile(`${process.pid}\n`);
			return async () => {
				await file.close();
				await rm(SESSIONS_SPEC_LOCK, { force: true });
			};
		} catch (error) {
			if (!isFileExists(error) || Date.now() > deadline) throw error;
			await sleep(100);
		}
	}
}

async function executeWithBusyRetry(
	db: ReturnType<typeof createClient>,
	sql: string,
): Promise<void> {
	let lastError: unknown;
	for (let attempt = 0; attempt < 6; attempt += 1) {
		try {
			await db.execute(sql);
			return;
		} catch (error) {
			if (!isSqliteBusy(error)) throw error;
			lastError = error;
			await sleep(50 * 2 ** attempt);
		}
	}
	throw lastError;
}

async function createSessionForRepo(
	page: Page,
	repo = "fairchild/workspaces",
): Promise<void> {
	await page.goto("/");
	const picker = page.getByTestId("new-session-picker");
	if (!(await picker.isVisible())) {
		await page.getByRole("button", { name: "+ new session" }).click();
	}
	await page.getByRole("textbox", { name: "Repository (owner/name)" }).fill(repo);
	await page.keyboard.press("Enter");
	await expect(page).toHaveURL(SESSION_URL);
}

test.beforeAll(async ({}, testInfo) => {
	testInfo.setTimeout(SESSIONS_SPEC_LOCK_TIMEOUT);
	releaseSessionsSpecLock = await acquireSessionsSpecLock();
	// Warm the schema first: migrations run lazily on the first authorized
	// request, and in auth-bypass mode the unauthenticated readiness probe
	// never touches the session tables — so without this the DELETEs below can
	// hit tables that don't exist yet on a cold server.
	await fetch(`http://localhost:${process.env.E2E_PORT ?? 3100}/`, {
		headers: { cookie: "test-auth-login=fairchild" },
	});
	// Same file the e2e server opened (see e2e:server); libSQL file handles
	// are plain SQLite, safe to write from a second process.
	const db = createClient({
		url: `file:${path.resolve(__dirname, "../../.data/e2e.db")}`,
	});
	await db.execute("PRAGMA busy_timeout = 5000");
	for (const table of ["session_events", "sessions", "repos"]) {
		await executeWithBusyRetry(db, `DELETE FROM ${table}`);
	}
	db.close();
});

test.afterAll(async () => {
	await releaseSessionsSpecLock?.();
	releaseSessionsSpecLock = undefined;
});

test("an empty home shows the calm empty state with the picker open", async ({
	page,
}) => {
	await page.goto("/");
	await expect(page.getByText("No sessions yet.")).toBeVisible();
	await expect(page.getByTestId("new-session-picker")).toBeVisible();
	await expect(
		page.getByRole("textbox", { name: "Repository (owner/name)" }),
	).toBeVisible();
});

test("typing an owner/name creates the repo + session and routes to it", async ({
	page,
}) => {
	await page.goto("/");
	await page
		.getByRole("textbox", { name: "Repository (owner/name)" })
		.fill("fairchild/workspaces");
	await page.keyboard.press("Enter");

	await expect(page).toHaveURL(SESSION_URL);
	// The empty Folio session: masthead repo, calm note, autofocused compose.
	await expect(page.locator("header")).toContainText("fairchild/workspaces");
	// No title yet: the inline field is empty, showing the "New session"
	// placeholder rather than persisted text (#823).
	await expect(page.getByTestId("session-title")).toHaveValue("");
	await expect(page.getByTestId("session-title")).toHaveAttribute(
		"placeholder",
		"New session",
	);
	await expect(page.getByTestId("empty-transcript")).toContainText(
		"No turns yet.",
	);
	await expect(
		page.getByRole("textbox", { name: "Reply to Claude" }),
	).toBeFocused();
});

test("home lists the session and the picker now offers the repo", async ({
	page,
}) => {
	await page.goto("/");
	const row = page.getByRole("link", { name: /Untitled session/ });
	await expect(row).toContainText("fairchild/workspaces");
	await expect(row).toContainText(/just now|\dm ago/);

	// The affordance is quiet until asked; the connected repo is one click.
	await page.getByRole("button", { name: "+ new session" }).click();
	await page
		.getByTestId("new-session-picker")
		.getByRole("button", { name: "fairchild/workspaces" })
		.click();
	await expect(page).toHaveURL(SESSION_URL);

	// Two sessions now, newest first.
	await page.goto("/");
	await expect(page.getByRole("link", { name: /Untitled session/ })).toHaveCount(
		2,
	);
});

// The session the streamed-turn tests share, set by the first of them.
let turnSessionUrl = "";

test("sending a message streams a mock coding turn into the Folio transcript", async ({
	page,
}) => {
	await page.goto("/");
	await page
		.getByRole("link", { name: /Untitled session/ })
		.first()
		.click();
	await expect(page).toHaveURL(SESSION_URL);
	turnSessionUrl = page.url();

	const compose = page.getByRole("textbox", { name: "Reply to Claude" });
	await compose.fill("Fix the failing session test");
	await page.keyboard.press("Enter");

	// The user message lands at once; compose clears and holds while busy —
	// the send affordance becomes the stop control for the in-flight turn (#753).
	await expect(page.locator('[data-message-role="user"]')).toContainText(
		"Fix the failing session test",
	);
	await expect(page.getByTestId("empty-transcript")).toHaveCount(0);
	await expect(compose).toHaveValue("");
	await expect(page.getByRole("button", { name: "Send" })).toHaveCount(0);
	await expect(page.getByRole("button", { name: "Stop" })).toBeVisible();

	// The activity line breathes while the provider provisions.
	await expect(page.getByTestId("activity-line")).toBeVisible();

	// The turn streams the whole apparatus: the thinking block…
	await expect(page.getByTestId("reasoning")).toBeVisible({
		timeout: TURN_TIMEOUT,
	});
	// …prose…
	await expect(page.locator('[data-message-role="assistant"]')).toContainText(
		"Let me reproduce the failure first",
		{ timeout: TURN_TIMEOUT },
	);
	// …the tool ledger (a failing run, Read, Edit with its line delta, the
	// passing re-run)…
	const rows = page.getByTestId("tool-row");
	await expect(rows).toHaveCount(4, { timeout: TURN_TIMEOUT });
	await expect(rows.nth(0)).toContainText("Ran");
	await expect(rows.nth(0)).toContainText("failed");
	await expect(rows.nth(1)).toContainText("Read");
	await expect(rows.nth(2)).toContainText("+3 −1");
	await expect(rows.nth(3)).toContainText("Ran");
	await expect(rows.nth(3)).toContainText("pnpm test session");
	// …the landed edit's diff — its one home is the Edit row itself, never a
	// separate floating card.
	await expect(page.getByTestId("diff-card")).toHaveCount(0);
	await rows.nth(2).locator("button").first().click();
	await expect(rows.nth(2).getByTestId("diff-lines")).toContainText(
		"SessionNotFoundError",
	);
	await rows.nth(2).locator("button").first().click(); // collapse it back
	// …and the end-of-turn receipt derived from the stream.
	await expect(page.getByTestId("turn-stats")).toContainText(
		"4 tools · 1 file · +3 −1 · 4 tests",
		{ timeout: TURN_TIMEOUT },
	);

	// The completed thinking block has receded to its collapsed trigger.
	await expect(page.getByTestId("reasoning")).toContainText("Thought for");

	// The passing re-run discloses the highlighted output panel.
	await rows.nth(3).locator("button").first().click();
	await expect(page.getByTestId("test-output")).toContainText("4 passed");
	await expect(page.getByTestId("test-output")).toHaveAttribute(
		"data-passed",
		"true",
	);

	// Turn over: compose re-enables, the activity line is gone.
	await expect(page.getByRole("button", { name: "Send" })).toBeEnabled();
	await expect(page.getByTestId("activity-line")).toHaveCount(0);

	// The session titled itself from the turn just sent — masthead + tab (#823).
	await expect(page.getByTestId("session-title")).toHaveValue(
		"Fix the failing session test",
	);
	await expect(page).toHaveTitle("Fix the failing session test — Spaces");
});

test("the derived title shows on home and is inline-editable from the masthead, persisting across reload (#823)", async ({
	page,
}) => {
	await page.goto("/");
	await expect(
		page.getByRole("link", { name: /Fix the failing session test/ }),
	).toBeVisible();

	await page.goto(turnSessionUrl);
	const titleField = page.getByTestId("session-title");
	await expect(titleField).toHaveValue("Fix the failing session test");

	await titleField.fill("Renamed by hand");
	await titleField.press("Enter");
	await expect(page).toHaveTitle("Renamed by hand — Spaces");

	await page.reload();
	await expect(page.getByTestId("session-title")).toHaveValue("Renamed by hand");
	await expect(page).toHaveTitle("Renamed by hand — Spaces");

	await page.goto("/");
	await expect(page.getByRole("link", { name: /Renamed by hand/ })).toBeVisible();
	// A later turn on this session must not clobber the hand-edited title.
	await page.getByRole("link", { name: /Renamed by hand/ }).click();
	await expect(page).toHaveURL(SESSION_URL);
});

test("home search narrows the list and keyboard resume opens the selected session (#986)", async ({
	page,
}) => {
	await page.goto("/");
	const sessionLinks = page.locator("main ul li a");
	await expect(sessionLinks).toHaveCount(2);

	await page.keyboard.press("/");
	const search = page.getByRole("searchbox", { name: "Search sessions" });
	await expect(search).toBeFocused();
	await search.type("failing session");

	await expect(sessionLinks).toHaveCount(1);
	await expect(sessionLinks.first()).toContainText("Renamed by hand");

	await search.press("ArrowDown");
	await search.press("Enter");
	await expect(page).toHaveURL(turnSessionUrl);
});

test("a reload renders the same turn from the persisted event log", async ({
	page,
}) => {
	await page.goto(turnSessionUrl);
	await expect(page.locator('[data-message-role="user"]')).toContainText(
		"Fix the failing session test",
	);
	const reloadedRows = page.getByTestId("tool-row");
	await expect(reloadedRows).toHaveCount(4);
	await expect(page.getByTestId("diff-card")).toHaveCount(0);
	// The Edit row's own subject carries the file; expanding it reveals the diff.
	await expect(reloadedRows.nth(2)).toContainText("src/lib/session.ts");
	await reloadedRows.nth(2).locator("button").first().click();
	await expect(reloadedRows.nth(2).getByTestId("diff-lines")).toContainText(
		"SessionNotFoundError",
	);
	await expect(page.getByTestId("turn-stats")).toContainText(
		"4 tools · 1 file · +3 −1 · 4 tests",
	);
	// Nothing is in flight after a reload — the receipt is served, not replayed.
	await expect(page.getByTestId("activity-line")).toHaveCount(0);
});

test("the status line's model picker changes the model and persists across reload (#824)", async ({
	page,
}) => {
	await page.goto(turnSessionUrl);
	const select = page.getByTestId("model-select");

	// New sessions stamp the current-best model — Fable 5.
	await expect(select).toHaveValue("claude-fable-5");
	await expect(page.getByTestId("status-line")).toContainText("Fable 5");

	await select.selectOption("claude-sonnet-5");
	await expect(page.getByTestId("status-line")).toContainText("Sonnet 5");

	// The end-of-turn receipt from the earlier mock turn also gave the status
	// line a real context figure — no more fake "0 ctx" placeholder.
	await expect(page.getByTestId("status-line")).toContainText("ctx");

	await page.reload();
	await expect(page.getByTestId("model-select")).toHaveValue("claude-sonnet-5");
	await expect(page.getByTestId("status-line")).toContainText("Sonnet 5");
});

test("a turn survives a mid-stream reload and resumes to completion", async ({
	page,
}) => {
	await page.goto(turnSessionUrl);
	const compose = page.getByRole("textbox", { name: "Reply to Claude" });
	await compose.fill("Now add a regression test");
	await page.keyboard.press("Enter");

	// Wait until the second turn's first tool call landed in the log…
	await expect(page.getByTestId("tool-row")).toHaveCount(5, {
		timeout: TURN_TIMEOUT,
	});
	// …then abandon the stream mid-turn. The turn runs detached server-side, so
	// the reload does not kill it.
	await page.reload();

	// Both turns' user messages survive; the reopened tab resumes the in-flight
	// turn from the event log and it finishes — a second receipt lands and the
	// full ledger (both turns, 4 tools each) is present.
	await expect(page.locator('[data-message-role="user"]')).toHaveCount(2);
	await expect(page.getByTestId("turn-stats")).toHaveCount(2, {
		timeout: TURN_TIMEOUT,
	});
	await expect(page.getByTestId("tool-row")).toHaveCount(8);
	// Nothing is in flight once the resumed turn completes.
	await expect(page.getByTestId("activity-line")).toHaveCount(0);
});

test("closing the tab mid-turn does not kill it — a fresh tab catches up", async ({
	page,
	context,
}) => {
	// A brand-new session, isolated from the shared turn session above.
	await createSessionForRepo(page);
	const sessionUrl = page.url();

	const compose = page.getByRole("textbox", { name: "Reply to Claude" });
	await compose.fill("Fix the failing session test");
	await page.keyboard.press("Enter");
	// The turn is genuinely under way (first prose streamed) before we leave.
	await expect(page.locator('[data-message-role="assistant"]')).toContainText(
		"Let me reproduce the failure first",
		{ timeout: TURN_TIMEOUT },
	);

	// Close the tab entirely, then reopen the session in a fresh tab.
	await page.close();
	const reopened = await context.newPage();
	await reopened.goto(sessionUrl);

	// The detached turn kept running; the reopened tab resumes it from the log
	// and it completes — the receipt is the proof it caught up live.
	await expect(reopened.getByTestId("turn-stats")).toContainText(
		"4 tools · 1 file · +3 −1 · 4 tests",
		{ timeout: TURN_TIMEOUT },
	);
	await expect(reopened.getByTestId("activity-line")).toHaveCount(0);
});

// A failing turn (#808): mock-provider.ts's MOCK_TURN_ERROR_TRIGGER
// ("__mock_turn_error__" in the sent text) fails the turn deterministically
// instead of running the script — the hermetic seam for driving this without
// a real provider outage. The same provider spends that trigger once per
// session, so a retry re-sending the identical text succeeds.
test("a failing turn surfaces an inline failure + retry, live and after reload (#808)", async ({
	page,
}) => {
	// A brand-new session, isolated from the shared turn session above.
	await createSessionForRepo(page);

	const compose = page.getByRole("textbox", { name: "Reply to Claude" });
	await compose.fill("Fix the bug __mock_turn_error__");
	await page.keyboard.press("Enter");

	// The user's message lands at once — it is never at risk, durably
	// persisted before the turn even starts — and the activity line breathes
	// briefly while the mock "provisions".
	await expect(page.locator('[data-message-role="user"]')).toContainText(
		"Fix the bug",
	);
	await expect(page.getByTestId("activity-line")).toBeVisible();

	// The turn fails: a calm inline failure card (no toast/alert chrome) with
	// the stream's error text and a Retry action; compose re-enables.
	await expect(page.getByTestId("turn-failure")).toContainText(
		"Simulated turn failure (mock provider)",
		{ timeout: TURN_TIMEOUT },
	);
	await expect(page.getByTestId("activity-line")).toHaveCount(0);
	await expect(page.getByRole("button", { name: "Send" })).toBeEnabled();

	// Retry re-sends the turn's original text — recoverable, not lost, even
	// though the compose field itself cleared on the original submit — WITHOUT
	// a reload in between: this is the live-only path, where the failed
	// turn's card is tagged by a sticky client-side record (live-turn-error.ts)
	// rather than the server projection. A status-gated version of that record
	// would un-tag the card the instant this retry's turn leaves the "error"
	// status, making it vanish here even though the log still has it — so this
	// ordering (retry BEFORE reload) is the one that actually exercises that.
	// The mock has already spent its one guaranteed failure on this session,
	// so this attempt runs the normal script through to completion.
	const turns = page.locator("main section");
	const failedTurn = turns.first();
	await failedTurn.getByRole("button", { name: "Retry" }).click();
	await expect(turns).toHaveCount(2, { timeout: TURN_TIMEOUT });
	const retryTurn = turns.nth(1);
	await expect(retryTurn.locator('[data-message-role="user"]')).toHaveCount(1);
	await expect(
		retryTurn.locator('[data-message-role="user"]'),
	).toContainText("Fix the bug");
	await expect(retryTurn.getByTestId("turn-stats")).toContainText(
		"4 tools · 1 file · +3 −1 · 4 tests",
		{ timeout: TURN_TIMEOUT },
	);
	await expect(page.getByTestId("activity-line")).toHaveCount(0);

	// The failed turn's own card is still there, live — retry started a new
	// turn, it didn't erase the record of the failure.
	await expect(failedTurn.getByTestId("turn-failure")).toContainText(
		"Simulated turn failure (mock provider)",
	);

	// A reload projects the identical story from the persisted log — both the
	// failure card and the successful retry turn survive it, proving live and
	// reloaded agree throughout, not just in the moment right after failing.
	await page.reload();
	await expect(page.locator("main section")).toHaveCount(2);
	await expect(page.locator("main section").first().getByTestId("turn-failure")).toContainText(
		"Simulated turn failure (mock provider)",
	);
	await expect(page.locator('[data-message-role="user"]')).toHaveCount(2);
	await expect(page.locator("main section").nth(1).getByTestId("turn-stats")).toContainText(
		"4 tools · 1 file · +3 −1 · 4 tests",
	);
});

// GitHub-backed repo picker (#825): the /api/repos fixture list under
// AUTH_BYPASS covers both a real (non-"main") default branch landing in the
// masthead and a calm inline error for a repo the fixture directory doesn't
// recognize — the two behaviors #825 added over the old freetext-only flow.

test("connecting a repo via freetext records and shows its real default branch", async ({
	page,
}) => {
	await page.goto("/");
	await page.getByRole("button", { name: "+ new session" }).click();
	await page
		.getByRole("textbox", { name: "Repository (owner/name)" })
		.fill("fairchild/web-next-fixtures");
	await page.keyboard.press("Enter");

	await expect(page).toHaveURL(SESSION_URL);
	await expect(page.locator("header")).toContainText("fairchild/web-next-fixtures");
	// The fixture's default_branch is "trunk" — distinct from the "main"
	// fallback, so this proves the real value was recorded and rendered.
	await expect(page.locator("header")).toContainText("trunk");
});

test("an owner/name the fixture directory doesn't recognize shows a calm inline error", async ({
	page,
}) => {
	await page.goto("/");
	await page.getByRole("button", { name: "+ new session" }).click();
	const input = page.getByRole("textbox", { name: "Repository (owner/name)" });
	await input.fill("fairchild/does-not-exist");
	await page.keyboard.press("Enter");

	// No navigation — the picker stays put with a quiet inline message.
	await expect(page).toHaveURL("/");
	await expect(page.getByTestId("new-session-error")).toContainText(
		"fairchild/does-not-exist",
	);
	await expect(page.getByTestId("new-session-picker")).toBeVisible();
});
