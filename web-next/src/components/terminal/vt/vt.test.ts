import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { terminalVtSpikeEnabled } from "@/app/(app)/dev/terminal-vt/gate";
import { ghosttyKeyName } from "./canvas-terminal";
import { GHOSTTY_VT_RELEASE, instantiateVt, verifySha256, VtTerminal } from "./ghostty-vt";
import { backgroundSpans, paintedCells } from "./paint";
import { PLAIN_STYLE, RunBuilder, selectionText, type TerminalSnapshot } from "./snapshot";

const bold = { ...PLAIN_STYLE, bold: true };

function snapshotOf(lines: TerminalSnapshot["lines"], cursor: TerminalSnapshot["cursor"] = null): TerminalSnapshot {
	return {
		columns: 10,
		rows: lines.length,
		fg: 0x111111,
		bg: 0xeeeeee,
		cursor,
		lines,
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
});

describe("selectionText", () => {
	it("copies across rows, wide cells once, trimmed", () => {
		const s = snapshotOf([
			[{ column: 0, cells: [..."hello"], columns: 5, style: PLAIN_STYLE }],
			[
				{ column: 0, cells: ["完"], columns: 2, style: PLAIN_STYLE },
				{ column: 2, cells: [..."ok"], columns: 2, style: PLAIN_STYLE },
			],
		]);
		expect(selectionText(s, { row: 1, column: 3 }, { row: 0, column: 2 })).toBe("llo\n完ok");
	});
});

describe("paint rules", () => {
	it("swaps colors for inverse and for the cursor cell, and merges backgrounds", () => {
		const s = snapshotOf(
			[[{ column: 0, cells: [..."ab"], columns: 2, style: { ...PLAIN_STYLE, inverse: true } }]],
			{ column: 1, row: 0, wide: false },
		);
		const cells = paintedCells(s, true);
		expect(cells.map((c) => [c.text, c.fg, c.bg])).toEqual([
			["a", 0xeeeeee, 0x111111],
			["b", 0x111111, null],
		]);
		expect(backgroundSpans(cells)).toEqual([{ row: 0, column: 0, width: 1, color: 0x111111 }]);
	});

	it("paints a cursor on an empty cell", () => {
		const s = snapshotOf([[]], { column: 3, row: 0, wide: false });
		expect(paintedCells(s, true).map((c) => [c.column, c.bg])).toEqual([[3, 0x111111]]);
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
const wasmPath = join(served, GHOSTTY_VT_RELEASE.builds.small.file);

describe.skipIf(!existsSync(wasmPath))("libghostty-vt 1.0 release wasm (run `pnpm spike:ghostty-vt` first)", () => {
	async function terminal(columns = 60, rows = 14) {
		const bytes = readFileSync(wasmPath);
		const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
		await verifySha256(buffer, GHOSTTY_VT_RELEASE.builds.small.sha256);
		const replies: string[] = [];
		const m = await instantiateVt(buffer);
		const t = new VtTerminal(m, { columns, rows, onReply: (b) => replies.push(new TextDecoder().decode(b)) });
		return { m, t, replies };
	}

	it("renders the recorded agent turn", async () => {
		const { t } = await terminal();
		const fixture = readFileSync(join(served, "agent-turn.vt"));
		for (let i = 0; i < fixture.length; i += 24) t.write(fixture.subarray(i, i + 24));
		const s = t.snapshot();
		const text = selectionText(s, { row: 0, column: 0 }, { row: s.rows - 1, column: s.columns - 1 });
		expect(text).toContain("✔ 6 tests passed");
		expect(text).toContain("│ wide: 完成 ✅  256-color  truecolor │");
		expect(s.cursor).toEqual({ column: 12, row: 9, wide: false });
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
		const decode = (b: Uint8Array) => new TextDecoder().decode(b);
		expect(decode(t.encodeKey(up))).toBe("\x1b[A");
		t.write("\x1b[?1h");
		expect(decode(t.encodeKey(up))).toBe("\x1bOA");
		t.write("\x1b[?2004h");
		expect(decode(t.encodePaste("ls\x1b[201~id\r"))).toBe("\x1b[200~ls [201~id\r\x1b[201~");
		t.dispose();
	});
});
