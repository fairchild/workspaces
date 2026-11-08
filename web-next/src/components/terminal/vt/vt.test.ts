import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { terminalVtSpikeEnabled } from "@/app/(app)/dev/terminal-vt/gate";
import { ghosttyKeyName, keyInput, MODS } from "./canvas-terminal";
import { GHOSTTY_VT_RELEASE, instantiateVt, type SurfaceGeometry, VtModule, verifySha256, VtTerminal } from "./ghostty-vt";
import { backgroundSpans, cursorKind, paintedCells, preeditCells } from "./paint";
import {
	hyperlinkRunAt,
	PLAIN_STYLE,
	RunBuilder,
	rangeText,
	type TerminalCursor,
	type TerminalSnapshot,
	viewportText,
} from "./snapshot";

const bold = { ...PLAIN_STYLE, bold: true };
const at = (column: number, row: number, extra: Partial<TerminalCursor> = {}): TerminalCursor => ({
	column,
	row,
	wide: false,
	shape: "block",
	blinking: false,
	...extra,
});

function snapshotOf(lines: TerminalSnapshot["lines"], cursor: TerminalSnapshot["cursor"] = null): TerminalSnapshot {
	return {
		columns: 10,
		rows: lines.length,
		fg: 0x111111,
		bg: 0xeeeeee,
		cursor,
		lines,
		selection: lines.map(() => null),
		scrollback: { total: lines.length, offset: 0, length: lines.length },
	};
}

describe("RunBuilder", () => {
	it("merges narrow cells of one style and drops trailing blanks", () => {
		const b = new RunBuilder();
		for (const c of "ab") b.append(c, 1, PLAIN_STYLE);
		b.append("c", 1, bold);
		for (const c of "   ") b.append(c, 1, PLAIN_STYLE);
		expect(b.finish().map((r) => [r.column, r.cells.join(""), r.columns])).toEqual([
			[0, "ab", 2],
			[2, "c", 1],
		]);
	});

	it("keeps a wide cell alone and counts its spacer column", () => {
		const b = new RunBuilder();
		b.append("完", 2, PLAIN_STYLE);
		b.skip();
		b.append("x", 1, PLAIN_STYLE);
		expect(b.finish().map((r) => [r.column, r.cells.join(""), r.columns])).toEqual([
			[0, "完", 2],
			[2, "x", 1],
		]);
	});

	it("keeps trailing blanks that paint a background", () => {
		const b = new RunBuilder();
		b.append(" ", 1, { ...PLAIN_STYLE, bg: 0x0000ff });
		expect(b.finish()).toHaveLength(1);
	});

	it("splits a hyperlink from the plain text beside it", () => {
		const b = new RunBuilder();
		for (const c of "go") b.append(c, 1, { ...PLAIN_STYLE, hyperlink: true });
		b.append("!", 1, PLAIN_STYLE);
		expect(b.finish().map((r) => [r.cells.join(""), r.style.hyperlink])).toEqual([
			["go", true],
			["!", false],
		]);
	});
});

describe("snapshot text", () => {
	const s = snapshotOf([
		[{ column: 0, cells: [..."hello"], columns: 5, style: PLAIN_STYLE }],
		[
			{ column: 0, cells: ["完"], columns: 2, style: PLAIN_STYLE },
			{ column: 2, cells: [..."ok"], columns: 2, style: { ...PLAIN_STYLE, hyperlink: true } },
		],
		[],
	]);

	it("copies a range across rows, wide cells once, trimmed", () => {
		expect(rangeText(s, { row: 1, column: 3 }, { row: 0, column: 2 })).toBe("llo\n完ok");
	});

	it("mirrors the viewport without trailing blank rows", () => {
		expect(viewportText(s)).toBe("hello\n完ok");
	});

	it("finds the hyperlink run under a cell", () => {
		expect(hyperlinkRunAt(s, { row: 1, column: 3 })).toEqual({ start: 2, end: 3 });
		expect(hyperlinkRunAt(s, { row: 1, column: 0 })).toBeNull();
	});
});

describe("paint rules", () => {
	it("swaps colors for inverse and for the cursor cell, and merges backgrounds", () => {
		const s = snapshotOf([[{ column: 0, cells: [..."ab"], columns: 2, style: { ...PLAIN_STYLE, inverse: true } }]], at(1, 0));
		const cells = paintedCells(s, true);
		expect(cells.map((c) => [c.text, c.fg, c.bg])).toEqual([
			["a", 0xeeeeee, 0x111111],
			["b", 0x111111, null],
		]);
		expect(backgroundSpans(cells)).toEqual([{ row: 0, column: 0, width: 1, color: 0x111111 }]);
	});

	it("paints a cursor on an empty cell", () => {
		const s = snapshotOf([[]], at(3, 0));
		expect(paintedCells(s, true).map((c) => [c.column, c.bg])).toEqual([[3, 0x111111]]);
	});

	it("draws the program's cursor shape while focused, a hollow box while not, and nothing in a blink's off phase", () => {
		const bar = snapshotOf([[]], at(0, 0, { shape: "bar", blinking: true }));
		expect(cursorKind(bar, true, true)).toBe("bar");
		expect(cursorKind(bar, true, false)).toBeNull();
		expect(cursorKind(bar, false, false)).toBe("hollow");
		expect(cursorKind(snapshotOf([[]], at(0, 0, { shape: "block_hollow" })), true, false)).toBe("hollow");
		expect(cursorKind(snapshotOf([[]], at(0, 0, { shape: "underline" })), true, false)).toBe("underline");
		expect(cursorKind(snapshotOf([[]]), true, true)).toBeNull();
	});

	it("lays a preedit out from the cursor by cell width, underlined, clipped at the edge", () => {
		const s = snapshotOf([[]], at(5, 0));
		const cells = preeditCells(s, [
			{ text: "日", width: 2 },
			{ text: "a", width: 1 },
			{ text: "本", width: 2 },
			{ text: "b", width: 1 },
		]);
		expect(cells.map((c) => [c.text, c.column, c.width, c.underline])).toEqual([
			["日", 5, 2, true],
			["a", 7, 1, true],
			["本", 8, 2, true],
		]);
	});
});

describe("ghosttyKeyName", () => {
	it("maps W3C codes to GhosttyKey names", () => {
		expect(["KeyA", "Digit1", "ArrowUp", "BracketLeft", "F12", "Numpad0", "ShiftLeft"].map(ghosttyKeyName)).toEqual([
			"A",
			"DIGIT_1",
			"ARROW_UP",
			"BRACKET_LEFT",
			"F12",
			"NUMPAD_0",
			"SHIFT_LEFT",
		]);
	});
});

describe("macOS Option policy", () => {
	const optionB = { key: "∫", code: "KeyB", altKey: true, shiftKey: false, ctrlKey: false, metaKey: false };
	const mac = (optionAsAlt: "false" | "true" | "left" | "right", altSide: "left" | "right" | null = "left") => ({
		mac: true,
		optionAsAlt,
		altSide,
	});

	it("composes by default: Option+B types ∫ with no Alt", () => {
		expect(keyInput(optionB, mac("false"))).toEqual({ mods: 0, text: "∫", unshiftedCodepoint: 98 });
	});

	it("sends Alt with the key's own character when Option is Alt", () => {
		expect(keyInput(optionB, mac("true"))).toEqual({ mods: MODS.alt, text: "b", unshiftedCodepoint: 98 });
		expect(keyInput({ ...optionB, key: "ı", shiftKey: true }, mac("true"))?.text).toBe("B");
	});

	it("applies a one-sided policy only to that Option key", () => {
		expect(keyInput(optionB, mac("left", "left"))?.mods).toBe(MODS.alt);
		expect(keyInput(optionB, mac("left", "right"))).toEqual({ mods: 0, text: "∫", unshiftedCodepoint: 98 });
		expect(keyInput(optionB, mac("right", "right"))?.mods).toBe(MODS.alt | MODS.altRight);
	});

	it("leaves a composing dead key to the IME, but sends it as Alt when Option is Alt", () => {
		const optionE = { ...optionB, key: "Dead", code: "KeyE" };
		expect(keyInput(optionE, mac("false"))).toBeNull();
		expect(keyInput(optionE, mac("true"))).toEqual({ mods: MODS.alt, text: "e", unshiftedCodepoint: 101 });
	});

	it("keeps Alt on keys that type nothing even while Option composes", () => {
		const optionLeft = { ...optionB, key: "ArrowLeft", code: "ArrowLeft" };
		expect(keyInput(optionLeft, mac("false"))).toEqual({ mods: MODS.alt, text: undefined, unshiftedCodepoint: 0 });
	});

	it("keeps Alt as Alt off macOS", () => {
		expect(keyInput({ ...optionB, key: "b" }, { mac: false, optionAsAlt: "false", altSide: "left" })).toEqual({
			mods: MODS.alt,
			text: "b",
			unshiftedCodepoint: 98,
		});
	});
});

describe("spike gate", () => {
	it("is on for the dev server and off in production unless asked for", () => {
		expect(terminalVtSpikeEnabled({ NODE_ENV: "development" } as NodeJS.ProcessEnv)).toBe(true);
		expect(terminalVtSpikeEnabled({ NODE_ENV: "production" } as NodeJS.ProcessEnv)).toBe(false);
		expect(
			terminalVtSpikeEnabled({ NODE_ENV: "production", WEB_NEXT_TERMINAL_VT_SPIKE: "1" } as NodeJS.ProcessEnv),
		).toBe(true);
	});
});

const served = join(process.cwd(), "public/dev/terminal-vt");
const wasmPath = join(served, GHOSTTY_VT_RELEASE.file);
const hasWasm = existsSync(wasmPath);
/** CI fetches the pinned wasm before this suite; there, a missing file is a failure, never a skip. */
const wasmRequired = process.env.CI === "true";

describe("libghostty-vt release wasm", () => {
	it.runIf(wasmRequired)("is present, so the wasm-backed tests run", () => {
		expect(hasWasm, `${wasmPath} missing: CI runs \`pnpm ghostty-vt:fetch\` before the unit tests`).toBe(true);
	});
});

function wasmBytes(): ArrayBuffer {
	const bytes = readFileSync(wasmPath);
	return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

async function terminal(columns = 60, rows = 14) {
	const buffer = wasmBytes();
	await verifySha256(buffer, GHOSTTY_VT_RELEASE.sha256);
	const replies: string[] = [];
	const m = await instantiateVt(buffer);
	const t = new VtTerminal(m, { columns, rows, onReply: (b) => replies.push(new TextDecoder().decode(b)) });
	return { m, t, replies };
}

async function screen(bytes: string, columns = 40, rows = 6) {
	const { t } = await terminal(columns, rows);
	t.write(bytes);
	const snapshot = t.snapshot();
	t.dispose();
	return snapshot;
}

const decode = (b: Uint8Array) => new TextDecoder().decode(b);

describe.skipIf(!hasWasm)("libghostty-vt 1.0 release wasm (run `pnpm ghostty-vt:fetch` first)", () => {
	it("renders the recorded agent turn", async () => {
		const { t } = await terminal();
		const fixture = readFileSync(join(served, "agent-turn.vt"));
		for (let i = 0; i < fixture.length; i += 24) t.write(fixture.subarray(i, i + 24));
		const s = t.snapshot();
		const text = viewportText(s);
		expect(text).toContain("✔ 6 tests passed");
		expect(text).toContain("│ wide: 完成 ✅  256-color  truecolor │");
		expect(s.cursor).toMatchObject({ column: 12, row: 9, wide: false });
		const truecolor = s.lines[6].find((r) => r.cells.join("") === "truecolor");
		expect(truecolor?.style.fg).toBe(0x78c8ff);
		t.dispose();
	});

	it("answers device queries, scrolls history, and encodes keys and pastes by mode", async () => {
		const { m, t, replies } = await terminal(40, 5);
		t.write("\x1b[c\x1b[6n");
		expect(replies).toEqual(["\x1b[?62;22c", "\x1b[1;1R"]);
		for (let i = 0; i < 20; i++) t.write(`line ${i}\r\n`);
		t.scrollViewport(-3);
		expect(t.snapshot().scrollback.offset).toBe(13);
		const up = { key: m.enumValue("GhosttyKey", "ARROW_UP"), mods: 0 };
		expect(decode(t.encodeKey(up))).toBe("\x1b[A");
		t.write("\x1b[?1h");
		expect(decode(t.encodeKey(up))).toBe("\x1bOA");
		t.write("\x1b[?2004h");
		expect(decode(t.encodePaste("ls\x1b[201~id\r"))).toBe("\x1b[200~ls [201~id\r\x1b[201~");
		t.dispose();
	});

	it("carries overline into the snapshot", async () => {
		const [x, y] = (await screen("\x1b[53mX\x1b[55mY", 20, 2)).lines[0];
		expect(x).toMatchObject({ cells: ["X"], style: { overline: true } });
		expect(y).toMatchObject({ cells: ["Y"], style: { overline: false } });
	});

	it("ignores writes after dispose and reuses the freed reply slot", async () => {
		const { m, t, replies } = await terminal(20, 2);
		const table = m.exports.__indirect_function_table;
		const size = table.length;
		t.dispose();
		t.write("\x1b[c");
		expect(replies).toEqual([]);
		const next = new VtTerminal(m, { columns: 20, rows: 2, onReply: (b) => replies.push(new TextDecoder().decode(b)) });
		expect(table.length).toBe(size);
		next.write("\x1b[c");
		expect(replies).toEqual(["\x1b[?62;22c"]);
		next.dispose();
	});

	it("sends replies after vt_write returns, so a synchronous echo cannot re-enter the parser", async () => {
		const { instance } = await WebAssembly.instantiate(wasmBytes(), {});
		const exports = { ...instance.exports } as Record<string, unknown>;
		const vtWrite = exports.ghostty_terminal_vt_write as (...args: number[]) => void;
		let inParser = 0;
		exports.ghostty_terminal_vt_write = (...args: number[]) => {
			inParser++;
			try {
				vtWrite(...args);
			} finally {
				inParser--;
			}
		};
		const m = new VtModule({ exports } as unknown as WebAssembly.Instance);
		const parserDepthAtReply: number[] = [];
		const t: VtTerminal = new VtTerminal(m, {
			columns: 20,
			rows: 3,
			onReply: () => {
				parserDepthAtReply.push(inParser);
				t.write("echo");
			},
		});
		t.write("\x1b[c");
		expect(parserDepthAtReply).toEqual([0]);
		t.dispose();
	});
});

/** Ported from ios/Packages/TerminalScreen's VirtualTerminalTests and TerminalSnapshotPaintingTests. */
describe.skipIf(!hasWasm)("edge cases the mobile package learned", () => {
	it("completes an escape sequence split across writes instead of printing it", async () => {
		const { t } = await terminal(20, 2);
		t.write("a\x1b[3");
		t.write("1mred\x1b[0m");
		const line = t.snapshot().lines[0];
		const text = line.map((r) => r.cells.join("")).join("");
		expect(text).toBe("ared");
		expect(text).not.toContain("\x1b");
		expect(line.at(-1)?.style.fg).not.toBeNull();
		t.dispose();
	});

	it("marks the whole wide character when the cursor sits on its right half", async () => {
		const s = await screen("完\x1b[1D", 4, 1);
		expect(s.cursor).toMatchObject({ column: 1, row: 0, wide: true });
		const cursor = paintedCells(s, true).find((c) => c.text === "完");
		expect(cursor).toMatchObject({ column: 0, width: 2, bg: s.fg });
	});

	it("shows the cursor on the cell a wrapped wide character left behind", async () => {
		const s = await screen("abc完\x1b[1;4H", 4, 2);
		expect(s.cursor).toMatchObject({ column: 3, row: 0 });
		const onCursor = paintedCells(s, true).filter((c) => c.row === 0 && c.bg === s.fg);
		expect(onCursor.map((c) => [c.column, c.width, c.text])).toEqual([[3, 1, " "]]);
	});

	it("paints a cell the terminal clusters as one grapheme in one column", async () => {
		const s = await screen("\x1b[?2027hA׈X\x1b[?25l");
		expect(paintedCells(s, false).map((c) => [c.text, c.column, c.width])).toEqual([
			["A׈", 0, 1],
			["X", 1, 1],
		]);
	});

	it("keeps cells a font would fuse into one grapheme in their own columns", async () => {
		const s = await screen("©‍®X\x1b[?25l");
		const cells = paintedCells(s, false);
		expect(cells.map((c) => c.column)).toEqual([0, 1, 2]);
		expect(cells.map((c) => c.width)).toEqual([1, 1, 1]);
		expect(cells.at(-1)?.text).toBe("X");
	});

	it("covers both columns of a clustered wide character with the cursor", async () => {
		const s = await screen("\x1b[?2027h完׈\x1b[1D", 4, 1);
		expect(s.cursor).toMatchObject({ column: 1, wide: true });
		const cursor = paintedCells(s, true).filter((c) => c.bg === s.fg);
		expect(cursor.map((c) => [c.text, c.column, c.width])).toEqual([["完׈", 0, 2]]);
	});
});

const surfaceOf = (t: VtTerminal): SurfaceGeometry => ({
	cellWidth: 10,
	cellHeight: 20,
	width: t.columns * 10,
	height: t.rows * 20,
});
const pointer = (column: number, row: number, dx = 5) => ({ column, row, x: column * 10 + dx, y: row * 20 + 10 });

describe.skipIf(!hasWasm)("parity the drawer needs before it leaves ghostty-web", () => {
	async function history() {
		const { m, t } = await terminal(20, 5);
		for (let i = 0; i < 20; i++) t.write(`line ${String(i).padStart(2, "0")}\r\n`);
		return { m, t, surface: surfaceOf(t) };
	}

	it("drags a selection that the terminal keeps through scrollback", async () => {
		const { t, surface } = await history();
		expect(t.selectionGesture("press", pointer(0, 0, 1), surface, 1000)).toBe(false);
		expect(t.selectionGesture("drag", pointer(6, 1, 9), surface)).toBe(true);
		t.selectionGesture("release", pointer(6, 1, 9), surface);
		expect(t.selectedText()).toBe("line 16\nline 17");
		expect(t.snapshot().selection.slice(0, 2)).toEqual([
			{ start: 0, end: 19 },
			{ start: 0, end: 6 },
		]);
		t.scrollViewport(-5);
		expect(t.snapshot().selection.every((row) => row === null)).toBe(true);
		t.scrollViewport(5);
		expect(t.snapshot().selection[1]).toEqual({ start: 0, end: 6 });
		expect(t.selectedText()).toBe("line 16\nline 17");
		expect(t.clearSelection()).toBe(true);
		expect(t.selectedText()).toBe("");
		t.dispose();
	});

	it("extends a drag held above the top edge into scrollback, one row per tick", async () => {
		const { t, surface } = await history();
		t.selectionGesture("press", pointer(0, 1, 1), surface, 1000);
		const above = { column: 0, row: 0, x: 1, y: -30 };
		t.selectionGesture("drag", above, surface);
		expect(t.autoscrollDirection()).toBe(-1);
		for (let i = 0; i < 3; i++) expect(t.autoscrollTick(above, surface)).toBe(true);
		const s = t.snapshot();
		expect(s.scrollback.offset).toBe(13);
		expect(t.selectedText().startsWith("line 13\nline 14\nline 15\nline 16")).toBe(true);
		t.dispose();
	});

	it("selects a word on double click and the whole line on triple click", async () => {
		const { t, surface } = await history();
		const click = (ms: number) => {
			t.selectionGesture("press", pointer(2, 2), surface, ms);
			t.selectionGesture("release", pointer(2, 2), surface);
		};
		click(1000);
		click(1100);
		expect(t.selectedText()).toBe("line");
		click(1200);
		expect(t.selectedText()).toBe("line 18");
		click(5000);
		expect(t.hasSelection()).toBe(false);
		t.dispose();
	});

	it("encodes mouse reports in the program's mode and format, and nothing without one", async () => {
		const { t } = await terminal(20, 5);
		const surface = surfaceOf(t);
		const report = (action: "press" | "release" | "motion", button: "left" | "wheel-up" | null, column: number, row: number, held = false) =>
			decode(t.encodeMouse({ action, button, mods: 0, ...pointer(column, row) }, surface, held));
		expect(t.mouseTracking()).toBe(false);
		expect(report("press", "left", 2, 1)).toBe("");
		t.write("\x1b[?1000h\x1b[?1006h");
		expect(t.mouseTracking()).toBe(true);
		expect(report("press", "left", 2, 1)).toBe("\x1b[<0;3;2M");
		expect(report("motion", "left", 3, 1, true)).toBe("");
		expect(report("release", "left", 2, 1)).toBe("\x1b[<0;3;2m");
		expect(report("press", "wheel-up", 0, 0)).toBe("\x1b[<64;1;1M");
		t.write("\x1b[?1002h");
		expect(report("motion", "left", 4, 1, true)).toBe("\x1b[<32;5;2M");
		t.write("\x1b[?1003h");
		expect(report("motion", null, 6, 2)).toBe("\x1b[<35;7;3M");
		t.write("\x1b[?1006l");
		expect(report("press", "left", 2, 1)).toBe("\x1b[M #\"");
		t.dispose();
	});

	it("reports motion once per cell, and again after a write re-reads the modes", async () => {
		const { t } = await terminal(20, 5);
		const surface = surfaceOf(t);
		t.write("\x1b[?1003h\x1b[?1006h");
		const move = (dx: number) => decode(t.encodeMouse({ action: "motion", button: null, mods: 0, ...pointer(4, 2, dx) }, surface, false));
		expect(move(2)).toBe("\x1b[<35;5;3M");
		expect(move(7)).toBe("");
		t.write("x");
		expect(move(7)).toBe("\x1b[<35;5;3M");
		t.dispose();
	});

	it("knows the alternate screen and its alternate-scroll mode", async () => {
		const { t } = await terminal(20, 5);
		expect(t.alternateScreen()).toBe(false);
		t.write("\x1b[?1049h\x1b[?1007h");
		expect(t.alternateScreen()).toBe(true);
		expect(t.mode(1007)).toBe(true);
		t.write("\x1b[?1049l");
		expect(t.alternateScreen()).toBe(false);
		t.dispose();
	});

	it("keeps thousands of scrollback lines, past the library's one-page default byte cap", async () => {
		const { t } = await terminal(80, 5);
		const line = `${"x".repeat(70)}\r\n`;
		t.write(line.repeat(5000));
		expect(t.snapshot().scrollback.total).toBeGreaterThan(4000);
		t.dispose();
	});

	it("copies a selection longer than the formatter's first buffer", async () => {
		const { t } = await terminal(80, 5);
		for (let i = 0; i < 200; i++) t.write(`${String(i).padStart(4, "0")} ${"y".repeat(60)}\r\n`);
		const surface = surfaceOf(t);
		t.selectionGesture("press", pointer(0, 4, 1), surface, 1000);
		const above = { column: 0, row: 0, x: 1, y: -30 };
		t.selectionGesture("drag", above, surface);
		for (let i = 0; i < 120; i++) t.autoscrollTick(above, surface);
		const text = t.selectedText();
		expect(text.length).toBeGreaterThan(4096);
		expect(text).toContain(`0100 ${"y".repeat(60)}`);
		t.dispose();
	});

	it("reports focus only after the program asks with mode 1004", async () => {
		const { t } = await terminal(20, 2);
		expect(decode(t.encodeFocus(true))).toBe("");
		t.write("\x1b[?1004h");
		expect(decode(t.encodeFocus(true))).toBe("\x1b[I");
		expect(decode(t.encodeFocus(false))).toBe("\x1b[O");
		t.dispose();
	});

	it("marks OSC 8 hyperlink cells and resolves their URI", async () => {
		const { t } = await terminal(30, 2);
		t.write("\x1b]8;;https://example.com/docs\x1b\\docs\x1b]8;;\x1b\\ plain");
		const line = t.snapshot().lines[0];
		expect(line.map((r) => [r.cells.join(""), r.style.hyperlink])).toEqual([
			["docs", true],
			[" plain", false],
		]);
		expect(t.hyperlinkAt({ row: 0, column: 1 })).toBe("https://example.com/docs");
		expect(t.hyperlinkAt({ row: 0, column: 6 })).toBeNull();
		t.dispose();
	});

	it("carries the cursor shape and blink the program set with DECSCUSR", async () => {
		const { t } = await terminal(20, 2);
		const cursor = (sequence: string) => {
			t.write(sequence);
			const c = t.snapshot().cursor;
			return c && { shape: c.shape, blinking: c.blinking };
		};
		expect(cursor("\x1b[5 q")).toEqual({ shape: "bar", blinking: true });
		expect(cursor("\x1b[2 q")).toEqual({ shape: "block", blinking: false });
		expect(cursor("\x1b[3 q")).toEqual({ shape: "underline", blinking: true });
		expect(cursor("\x1b[6 q")).toEqual({ shape: "bar", blinking: false });
		t.dispose();
	});

	it("measures preedit graphemes with the terminal's widths", async () => {
		const { m } = await terminal(10, 1);
		expect(m.graphemeWidths("日本a")).toEqual([
			{ text: "日", width: 2 },
			{ text: "本", width: 2 },
			{ text: "a", width: 1 },
		]);
		expect(m.graphemeWidths("éx").map((g) => g.text)).toEqual(["é", "x"]);
	});

	it("turns the macOS Option policy into the bytes a shell expects", async () => {
		const { m, t } = await terminal(20, 2);
		const key = m.enumValue("GhosttyKey", "B");
		const optionB = { key: "∫", code: "KeyB", altKey: true, shiftKey: false, ctrlKey: false, metaKey: false };
		const asAlt = keyInput(optionB, { mac: true, optionAsAlt: "true", altSide: "left" })!;
		const composing = keyInput(optionB, { mac: true, optionAsAlt: "false", altSide: "left" })!;
		expect(decode(t.encodeKey({ key, ...asAlt }))).toBe("\x1bb");
		expect(decode(t.encodeKey({ key, ...composing }))).toBe("∫");
		t.dispose();
	});
});
