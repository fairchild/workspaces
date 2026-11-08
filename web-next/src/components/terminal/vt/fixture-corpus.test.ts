/*
 * Replays the shared libghostty-vt fixture corpus (`fixtures/terminal-vt/` at
 * the repo root) and compares each final screen with its golden. The mobile
 * package's FixtureCorpusTests replays the same files against the same
 * goldens, so the two bindings answer to one contract. Goldens hold only the
 * fields both snapshots expose, in a canonical run shape both tests derive.
 * `UPDATE_VT_GOLDENS=1` rewrites the goldens instead of comparing.
 */
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { GHOSTTY_VT_RELEASE, instantiateVt, VtTerminal, verifySha256 } from "./ghostty-vt";
import type { CellStyle, TerminalSnapshot, TextRun } from "./snapshot";

const corpusDir = join(process.cwd(), "../fixtures/terminal-vt");
const harnessFixture = join(process.cwd(), "public/dev/terminal-vt/agent-turn.vt");
const wasmPath = join(process.cwd(), "public", GHOSTTY_VT_RELEASE.servedFrom, GHOSTTY_VT_RELEASE.file);
const hasWasm = existsSync(wasmPath);
const updating = process.env.UPDATE_VT_GOLDENS === "1";

interface Fixture {
	name: string;
	columns: number;
	rows: number;
	/** Bytes per write; the whole stream in one write when absent. */
	chunk?: number;
	about: string;
}

/** Only set fields appear: no key means the default color, or the attribute off. */
interface GoldenStyle {
	fg?: string;
	bg?: string;
	bold?: true;
	italic?: true;
	faint?: true;
	underline?: true;
	strikethrough?: true;
	inverse?: true;
	invisible?: true;
}

interface GoldenRun {
	column: number;
	text: string;
	columns: number;
	style?: GoldenStyle;
}

interface Golden {
	columns: number;
	rows: number;
	fg: string;
	bg: string;
	cursor: { column: number; row: number; wide: boolean } | null;
	lines: GoldenRun[][];
}

interface Cell {
	column: number;
	text: string;
	width: number;
	style: GoldenStyle | undefined;
	paintsBlank: boolean;
}

const fixtures: Fixture[] = JSON.parse(readFileSync(join(corpusDir, "corpus.json"), "utf8")).fixtures;

const hex = (rgb: number) => `#${rgb.toString(16).padStart(6, "0")}`;

function goldenStyle(style: CellStyle): GoldenStyle | undefined {
	const out: GoldenStyle = {};
	if (style.fg !== null) out.fg = hex(style.fg);
	if (style.bg !== null) out.bg = hex(style.bg);
	for (const flag of ["bold", "italic", "faint", "underline", "strikethrough", "inverse", "invisible"] as const) {
		if (style[flag]) out[flag] = true;
	}
	return Object.keys(out).length > 0 ? out : undefined;
}

function cellsOf(line: TextRun[]): Cell[] {
	return line.flatMap((run) => {
		const style = goldenStyle(run.style);
		const paintsBlank = run.style.bg !== null || run.style.inverse || run.style.underline || run.style.strikethrough;
		if (run.columns === 2 && run.cells.length === 1) {
			return [{ column: run.column, text: run.cells[0], width: 2, style, paintsBlank }];
		}
		return run.cells.map((text, i) => ({ column: run.column + i, text, width: 1, style, paintsBlank }));
	});
}

/**
 * The canonical runs: trailing blanks that paint nothing dropped, then narrow
 * single-code-point cells of one style merged. A wide cell, or a cell holding
 * several code points, is a run of its own, so `text` always splits back into
 * cells without knowing either language's grapheme rules.
 */
function canonicalRuns(cells: Cell[]): GoldenRun[] {
	const kept = [...cells];
	while (kept.length > 0 && kept[kept.length - 1].text === " " && !kept[kept.length - 1].paintsBlank) kept.pop();
	const runs: GoldenRun[] = [];
	let mergeable = false;
	for (const cell of kept) {
		const narrow = cell.width === 1 && [...cell.text].length === 1;
		const last = runs.at(-1);
		if (
			narrow &&
			mergeable &&
			last &&
			last.column + last.columns === cell.column &&
			JSON.stringify(last.style) === JSON.stringify(cell.style)
		) {
			last.text += cell.text;
			last.columns += 1;
			continue;
		}
		runs.push({ column: cell.column, text: cell.text, columns: cell.width, ...(cell.style ? { style: cell.style } : {}) });
		mergeable = narrow;
	}
	return runs;
}

function golden(snapshot: TerminalSnapshot): Golden {
	return {
		columns: snapshot.columns,
		rows: snapshot.rows,
		fg: hex(snapshot.fg),
		bg: hex(snapshot.bg),
		cursor: snapshot.cursor && { column: snapshot.cursor.column, row: snapshot.cursor.row, wide: snapshot.cursor.wide },
		lines: snapshot.lines.map((line) => canonicalRuns(cellsOf(line))),
	};
}

/** One run per line, so a golden diff reads cell by cell. */
function formatGolden(g: Golden): string {
	const lines = g.lines.map((runs) =>
		runs.length === 0 ? "    []" : `    [\n${runs.map((run) => `      ${JSON.stringify(run)}`).join(",\n")}\n    ]`,
	);
	return [
		"{",
		`  "columns": ${g.columns},`,
		`  "rows": ${g.rows},`,
		`  "fg": ${JSON.stringify(g.fg)},`,
		`  "bg": ${JSON.stringify(g.bg)},`,
		`  "cursor": ${JSON.stringify(g.cursor)},`,
		`  "lines": [\n${lines.join(",\n")}\n  ]`,
		"}",
		"",
	].join("\n");
}

async function replay(fixture: Fixture): Promise<TerminalSnapshot> {
	const bytes = readFileSync(wasmPath);
	const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
	await verifySha256(buffer, GHOSTTY_VT_RELEASE.sha256);
	const t = new VtTerminal(await instantiateVt(buffer), { columns: fixture.columns, rows: fixture.rows });
	const stream = readFileSync(join(corpusDir, `${fixture.name}.vt`));
	const chunk = fixture.chunk ?? stream.length;
	for (let i = 0; i < stream.length; i += chunk) t.write(stream.subarray(i, i + chunk));
	const snapshot = t.snapshot();
	t.dispose();
	return snapshot;
}

describe("libghostty-vt fixture corpus", () => {
	it.runIf(process.env.CI === "true")("has the pinned wasm in CI, so the replay runs rather than skips", () => {
		expect(hasWasm, `${wasmPath} missing: CI runs \`pnpm ghostty-vt:fetch\` before the unit tests`).toBe(true);
	});

	it("lists every stream in the directory, and every listed fixture has a stream", () => {
		const streams = readdirSync(corpusDir)
			.filter((f) => f.endsWith(".vt"))
			.map((f) => f.slice(0, -3))
			.sort();
		expect(fixtures.map((f) => f.name).sort()).toEqual(streams);
	});

	it("keeps the drawer harness's agent turn identical to the corpus copy", () => {
		expect(readFileSync(harnessFixture).equals(readFileSync(join(corpusDir, "agent-turn.vt")))).toBe(true);
	});
});

describe.skipIf(!hasWasm)("libghostty-vt fixture corpus replay (run `pnpm ghostty-vt:fetch` first)", () => {
	it.each(fixtures.map((f) => [f.name, f] as const))("%s matches its golden", async (name, fixture) => {
		const actual = golden(await replay(fixture));
		const path = join(corpusDir, `${name}.golden.json`);
		if (updating) {
			expect(process.env.CI, "UPDATE_VT_GOLDENS rewrites goldens instead of checking them; CI must compare").not.toBe("true");
			writeFileSync(path, formatGolden(actual));
			return;
		}
		expect(existsSync(path), `${path} missing: run with UPDATE_VT_GOLDENS=1 to write it`).toBe(true);
		const expected: Golden = JSON.parse(readFileSync(path, "utf8"));
		const { lines: expectedLines, ...expectedScreen } = expected;
		const { lines: actualLines, ...actualScreen } = actual;
		expect(actualScreen, `${name} screen`).toEqual(expectedScreen);
		expect(actualLines.length, `${name} line count`).toBe(expectedLines.length);
		actualLines.forEach((line, row) => {
			expect(line, `${name} row ${row}`).toEqual(expectedLines[row]);
		});
	});
});
