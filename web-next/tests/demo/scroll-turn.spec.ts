/*
 * Filmed proof for #1015: after a completed turn creates real scrollback, a
 * directly sent follow-up keeps its growing lower edge above the composer.
 */
import { expect, type Page, test } from "@playwright/test";

const TURN_TIMEOUT = 20_000;
const MAX_NATURAL_FRAME_DELTA_PX = 26;

interface ScrollSample {
	at: number;
	y: number;
}

async function startScrollTrace(page: Page): Promise<void> {
	await page.evaluate(() => {
		const trace = { frame: 0, samples: [] as ScrollSample[] };
		const sample = (at: number) => {
			trace.samples.push({ at, y: window.scrollY });
			trace.frame = window.requestAnimationFrame(sample);
		};
		trace.frame = window.requestAnimationFrame(sample);
		(
			window as typeof window & {
				__scrollFollowTrace?: typeof trace;
			}
		).__scrollFollowTrace = trace;
	});
}

async function stopScrollTrace(page: Page): Promise<ScrollSample[]> {
	return await page.evaluate(() => {
		const trace = (
			window as typeof window & {
				__scrollFollowTrace?: { frame: number; samples: ScrollSample[] };
			}
		).__scrollFollowTrace;
		if (!trace) return [];
		window.cancelAnimationFrame(trace.frame);
		return trace.samples;
	});
}

async function expectActiveTurnAboveComposer(page: Page): Promise<void> {
	const recentTurn = page.locator('section[data-turn="recent"]');
	const compose = page.getByRole("textbox", { name: "Reply to Claude" });
	await expect
		.poll(async () => {
			const [turnBox, composeBox] = await Promise.all([
				recentTurn.boundingBox(),
				compose.boundingBox(),
			]);
			if (!turnBox || !composeBox) return Number.POSITIVE_INFINITY;
			return turnBox.y + turnBox.height - composeBox.y;
		})
		.toBeLessThanOrEqual(-8);
}

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

test("a directly sent follow-up naturally follows its growing bottom", async ({
	page,
}, testInfo) => {
	await createSession(page);
	const compose = page.getByRole("textbox", { name: "Reply to Claude" });

	await compose.fill("Build enough scrollback for the auto-scroll demo");
	await page.keyboard.press("Enter");
	await expect(page.getByTestId("turn-stats")).toHaveCount(1, {
		timeout: TURN_TIMEOUT,
	});
	await page.waitForTimeout(1_000);

	// Recreate the real reading state: the owner has moved back into old
	// scrollback, while the sticky compose remains available at the bottom.
	await page.evaluate(() => window.scrollTo(0, 0));
	await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(0);
	await page.waitForTimeout(1_000);

	await compose.pressSequentially(
		"Keep this active turn above the composer while it grows",
		{ delay: 24 },
	);
	await page.waitForTimeout(500);
	await startScrollTrace(page);
	await page.getByRole("button", { name: "Send" }).click();

	const recentTurn = page.locator('section[data-turn="recent"]');
	await expect(recentTurn).toContainText(
		"Keep this active turn above the composer while it grows",
	);
	const initialTurnHeight = (await recentTurn.boundingBox())?.height ?? 0;
	await expect
		.poll(async () => (await recentTurn.boundingBox())?.height ?? 0, {
			timeout: TURN_TIMEOUT,
		})
		.toBeGreaterThan(initialTurnHeight + 160);
	await expectActiveTurnAboveComposer(page);
	await expect(page.getByTestId("turn-stats")).toHaveCount(2, {
		timeout: TURN_TIMEOUT,
	});
	await expectActiveTurnAboveComposer(page);

	// Keep the final proven position visible in the recorded artifact.
	await page.waitForTimeout(1_500);
	const samples = await stopScrollTrace(page);
	const frameDeltas = samples
		.slice(1)
		.map((sample, index) => Math.abs(sample.y - samples[index].y));
	const maxFrameDelta = Math.max(0, ...frameDeltas);
	const movingFrames = frameDeltas.filter((delta) => delta > 0.5).length;
	const scrollTravel =
		Math.max(...samples.map(({ y }) => y)) -
		Math.min(...samples.map(({ y }) => y));
	await testInfo.attach("scroll-trace", {
		body: JSON.stringify(
			{
				sampleCount: samples.length,
				maxFrameDelta,
				movingFrames,
				scrollTravel,
				samples,
			},
			null,
			2,
		),
		contentType: "application/json",
	});
	expect(scrollTravel).toBeGreaterThan(400);
	expect(movingFrames).toBeGreaterThan(10);
	expect(maxFrameDelta).toBeLessThanOrEqual(MAX_NATURAL_FRAME_DELTA_PX);
});

test("manual upward scrolling pauses follow while the turn keeps growing", async ({
	page,
}) => {
	await createSession(page);
	const compose = page.getByRole("textbox", { name: "Reply to Claude" });

	await compose.fill("Build scrollback before testing manual pause");
	await page.keyboard.press("Enter");
	await expect(page.getByTestId("turn-stats")).toHaveCount(1, {
		timeout: TURN_TIMEOUT,
	});
	await page.waitForTimeout(1_000);

	await compose.fill("Keep streaming while I inspect older output");
	await page.keyboard.press("Enter");
	const recentTurn = page.locator('section[data-turn="recent"]');
	await expect(recentTurn).toContainText(
		"Keep streaming while I inspect older output",
	);
	await expect(page.getByRole("button", { name: "Stop" })).toBeVisible();
	await expect
		.poll(() => page.evaluate(() => window.scrollY))
		.toBeGreaterThan(150);
	const followedScrollY = await page.evaluate(() => window.scrollY);
	const turnHeightBeforePause = (await recentTurn.boundingBox())?.height ?? 0;

	await page.mouse.move(100, 180);
	await page.mouse.wheel(0, -500);
	await page.waitForTimeout(80);
	const pausedScrollY = await page.evaluate(() => window.scrollY);
	expect(pausedScrollY).toBeLessThan(followedScrollY - 100);

	// More streamed layout lands after the user takes the wheel. Follow must
	// stay suspended instead of pulling the viewport back to the active tail.
	await expect
		.poll(async () => (await recentTurn.boundingBox())?.height ?? 0, {
			timeout: TURN_TIMEOUT,
		})
		.toBeGreaterThan(turnHeightBeforePause + 60);
	const afterGrowthScrollY = await page.evaluate(() => window.scrollY);
	expect(Math.abs(afterGrowthScrollY - pausedScrollY)).toBeLessThanOrEqual(8);

	// Returning to the document tail opts back into follow. As more visible
	// output lands, the viewport should move with it again.
	for (let step = 0; step < 4; step += 1) {
		await page.mouse.wheel(0, 1_000);
		await page.waitForTimeout(50);
	}
	await expect
		.poll(() =>
			page.evaluate(
				() =>
					document.documentElement.scrollHeight -
					window.innerHeight -
					window.scrollY,
			),
		)
		.toBeLessThanOrEqual(8);
	await expect(page.getByRole("button", { name: "Stop" })).toBeVisible();
	const resumedScrollY = await page.evaluate(() => window.scrollY);
	const turnHeightAtResume = (await recentTurn.boundingBox())?.height ?? 0;
	await expect
		.poll(async () => (await recentTurn.boundingBox())?.height ?? 0, {
			timeout: TURN_TIMEOUT,
		})
		.toBeGreaterThan(turnHeightAtResume + 40);
	await expect
		.poll(() => page.evaluate(() => window.scrollY))
		.toBeGreaterThan(resumedScrollY + 20);
	await expectActiveTurnAboveComposer(page);
});
