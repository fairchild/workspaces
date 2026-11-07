/*
 * The libghostty-vt canvas terminal at /dev/terminal-vt (#1847), in a real
 * browser over Ghostty's pinned release wasm: the recorded fixture renders,
 * and each behavior the drawer needs before #1848 cuts over works through
 * real pointer, keyboard, focus and IME events. Screenshots land in
 * output/terminal-vt/, which CI uploads as the terminal-vt-evidence artifact
 * (pnpm evidence empties output/evidence/, so they live beside it).
 */
import { existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { expect, type Page, test } from "@playwright/test";

const WASM = path.resolve("public/dev/terminal-vt/ghostty-vt-1.0.0-small.wasm");
const OUT = path.resolve("output/terminal-vt");

test.skip(!existsSync(WASM) && process.env.CI !== "true", "run `pnpm ghostty-vt:fetch` first");
// The harness lays two 620px panes side by side; at the default 1280×720 they
// wrap and the vt pane's lower rows fall below the fold, out of the pointer's reach.
test.use({ viewport: { width: 1440, height: 900 } });

interface Geometry {
	left: number;
	top: number;
	cellWidth: number;
	cellHeight: number;
	rows: number;
	columns: number;
}

async function open(page: Page, query: string): Promise<Geometry> {
	await page.goto(`/dev/terminal-vt?pane=vt&${query}`);
	await expect(page.getByTestId("spike-metrics")).toContainText('"phase": "done"', { timeout: 20_000 });
	return page.evaluate(() => {
		const vt = window.__terminalVt!.vt;
		const rect = vt.canvas.getBoundingClientRect();
		return {
			left: rect.left,
			top: rect.top,
			cellWidth: rect.width / vt.columns,
			cellHeight: rect.height / vt.rows,
			rows: vt.rows,
			columns: vt.columns,
		};
	});
}

const center = (g: Geometry, column: number, row: number) => ({
	x: g.left + (column + 0.5) * g.cellWidth,
	y: g.top + (row + 0.5) * g.cellHeight,
});

async function rowOf(page: Page, line: string): Promise<number> {
	const row = await page.evaluate((text) => window.__terminalVt!.vt.text().split("\n").findIndex((l) => l.startsWith(text)), line);
	expect(row, `"${line}" on screen`).toBeGreaterThanOrEqual(0);
	return row;
}

const selected = (page: Page) => page.evaluate(() => window.__terminalVt!.vt.selectedText());
const sent = (page: Page) => page.evaluate(() => window.__terminalVt!.sent.join(""));
const canvasPixels = (page: Page) => page.evaluate(() => window.__terminalVt!.vt.canvas.toDataURL());

async function shot(page: Page, name: string): Promise<void> {
	mkdirSync(OUT, { recursive: true });
	await page.getByTestId("pane-vt").screenshot({ path: path.join(OUT, `${name}.png`) });
}

test("renders the recorded agent turn and mirrors it for screen readers", async ({ page }) => {
	await open(page, "source=fixture");
	const mirror = page.getByRole("document", { name: "Terminal screen" });
	await expect(mirror).toContainText("✔ 6 tests passed");
	await expect(mirror).toContainText("wide: 完成 ✅");
	await shot(page, "fixture");
});

test.describe("parity screen", () => {
	test("mirrors the viewport text, not the stream", async ({ page }) => {
		await open(page, "source=parity");
		const mirror = page.getByRole("document", { name: "Terminal screen" });
		await expect(mirror).toContainText("links: ghostty.org/docs and plain text");
		await expect(mirror).toContainText("history 39");
		await expect(mirror).not.toContainText("history 00");
	});

	test("triple click selects the whole line through Ghostty's gesture", async ({ page }) => {
		const g = await open(page, "source=parity");
		const row = await rowOf(page, "history 30");
		const { x, y } = center(g, 3, row);
		await page.mouse.click(x, y, { clickCount: 2 });
		expect(await selected(page)).toBe("history");
		await page.mouse.click(x + g.cellWidth * 10, y);
		await page.mouse.click(x, y, { clickCount: 3 });
		expect(await selected(page)).toBe("history 30");
		await shot(page, "triple-click-line");
	});

	test("a drag held above the top edge selects into scrollback", async ({ page }) => {
		const g = await open(page, "source=parity");
		const row = await rowOf(page, "history 30");
		const start = center(g, 0, row);
		await page.mouse.move(start.x - g.cellWidth / 3, start.y);
		await page.mouse.down();
		await page.mouse.move(start.x, g.top - 20, { steps: 5 });
		await page.waitForTimeout(700);
		await page.mouse.up();
		const text = await selected(page);
		const lines = text.split("\n");
		expect(lines.length).toBeGreaterThan(g.rows);
		expect(lines[0]).toMatch(/^history \d\d$/);
		expect(text).toContain("history 29");
		await shot(page, "scrollback-selection");
	});

	test("Ctrl+click opens an OSC 8 link, and hovering with Ctrl shows it", async ({ page }) => {
		const g = await open(page, "source=parity");
		const row = await rowOf(page, "links:");
		const { x, y } = center(g, 9, row);
		const probe = await page.evaluate(
			({ x, y, row }) => {
				const vt = window.__terminalVt!.vt;
				const s = vt.terminal.snapshot();
				return {
					hit: document.elementFromPoint(x, y)?.tagName ?? null,
					runs: s.lines[row].map((r) => [r.column, r.cells.join(""), r.style.hyperlink] as const),
					uri: vt.terminal.hyperlinkAt({ row, column: 9 }),
				};
			},
			{ x, y, row },
		);
		const detail = JSON.stringify(probe);
		expect(probe.hit, detail).toBe("CANVAS");
		expect(probe.uri, detail).toBe("https://ghostty.org/docs");
		expect(probe.runs.some(([, text, link]) => link && text.includes("ghostty.org/docs")), detail).toBe(true);
		await page.keyboard.down("Control");
		await page.mouse.move(x, y);
		await expect.poll(() => page.evaluate(() => window.__terminalVt!.vt.canvas.style.cursor)).toBe("pointer");
		await shot(page, "link-hover");
		await page.mouse.click(x, y);
		await page.keyboard.up("Control");
		expect(await page.evaluate(() => window.__terminalVt!.links)).toEqual(["https://ghostty.org/docs"]);
	});

	test("the program's blinking bar cursor blinks while focused", async ({ page }) => {
		await open(page, "source=parity");
		const cursor = await page.evaluate(() => window.__terminalVt!.vt.terminal.snapshot().cursor);
		expect(cursor).toMatchObject({ shape: "bar", blinking: true });
		await page.evaluate(() => window.__terminalVt!.vt.focus());
		const frames = new Set<string>();
		for (let i = 0; i < 3; i++) {
			frames.add(await canvasPixels(page));
			await page.waitForTimeout(650);
		}
		expect(frames.size).toBeGreaterThan(1);
		await shot(page, "cursor-bar");
	});

	test("IME composition shows inline until it commits", async ({ page }) => {
		await open(page, "source=parity");
		await page.evaluate(() => window.__terminalVt!.vt.focus());
		await page.waitForTimeout(100);
		const before = await canvasPixels(page);
		const cdp = await page.context().newCDPSession(page);
		await cdp.send("Input.imeSetComposition", { text: "日本", selectionStart: 2, selectionEnd: 2 });
		await expect.poll(() => canvasPixels(page)).not.toBe(before);
		expect(await sent(page)).not.toContain("日本");
		await shot(page, "ime-preedit");
		await cdp.send("Input.insertText", { text: "日本" });
		await expect.poll(() => sent(page)).toContain("日本");
	});

	test("mouse and focus reports go to a program that asked for them", async ({ page }) => {
		const g = await open(page, "source=parity");
		await page.evaluate(() => {
			const probe = window.__terminalVt!;
			probe.vt.write("\x1b[?1000h\x1b[?1006h\x1b[?1004h");
			probe.sent.length = 0;
		});
		const { x, y } = center(g, 2, 1);
		await page.mouse.click(x, y);
		await expect.poll(() => sent(page)).toContain("\x1b[<0;3;2M");
		expect(await sent(page)).toContain("\x1b[<0;3;2m");
		await page.mouse.wheel(0, -g.cellHeight * 2);
		await expect.poll(() => sent(page)).toContain("\x1b[<64;3;2M");
		await page.evaluate(() => {
			const probe = window.__terminalVt!;
			probe.sent.length = 0;
			probe.vt.blur();
			probe.vt.focus();
		});
		expect(await sent(page)).toBe("\x1b[O\x1b[I");
		expect(await selected(page)).toBe("");
	});
});

test.describe("macOS Option policy", () => {
	test.beforeEach(async ({ page }) => {
		await page.addInitScript(() => Object.defineProperty(Navigator.prototype, "platform", { get: () => "MacIntel" }));
	});

	for (const [policy, expected] of [
		["false", "∫"],
		["true", "\x1bb"],
	] as const) {
		test(`optionAsAlt=${policy}: Option+B sends ${JSON.stringify(expected)}`, async ({ page }) => {
			await open(page, `source=parity&optionAsAlt=${policy}`);
			await page.evaluate(() => {
				const probe = window.__terminalVt!;
				probe.vt.focus();
				probe.sent.length = 0;
				const fire = (init: KeyboardEventInit) =>
					probe.vt.textarea.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
				fire({ key: "Alt", code: "AltLeft", altKey: true });
				fire({ key: "∫", code: "KeyB", altKey: true });
			});
			expect(await sent(page)).toBe(expected);
		});
	}
});
