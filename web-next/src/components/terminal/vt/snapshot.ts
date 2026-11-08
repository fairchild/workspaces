/*
 * The screen as plain values, the web twin of the mobile package's
 * TerminalSnapshot: lines of styled runs on a fixed cell grid, the cursor with
 * its shape and blink, the default colors, and the selection as row-local
 * column ranges. A run is either narrow cells (one grapheme per column) or a
 * single wide cell, so the painter places glyphs on the grid without
 * measuring them. RunBuilder coalesces a row's cells into runs.
 */

/** 0xRRGGBB. */
export type Rgb = number;

export interface CellStyle {
	/** null = the terminal's default. */
	fg: Rgb | null;
	bg: Rgb | null;
	bold: boolean;
	italic: boolean;
	faint: boolean;
	inverse: boolean;
	invisible: boolean;
	strikethrough: boolean;
	underline: boolean;
	overline: boolean;
	/** The cell carries an OSC 8 hyperlink; the URI is looked up on demand. */
	hyperlink: boolean;
}

export interface TextRun {
	/** First column the run covers. */
	column: number;
	/** One grapheme per cell. */
	cells: string[];
	/** Columns covered: cells.length for narrow runs, 2 for a wide cell. */
	columns: number;
	style: CellStyle;
}

/** GhosttyCursorStyle, as the program set it with DECSCUSR. */
export type CursorShape = "block" | "bar" | "underline" | "block_hollow";

export interface TerminalCursor {
	column: number;
	row: number;
	/** The cursor sits on the right half of a wide character. */
	wide: boolean;
	shape: CursorShape;
	blinking: boolean;
}

/** Selected columns of one viewport row, inclusive on both ends. */
export interface RowSelection {
	start: number;
	end: number;
}

export interface TerminalSnapshot {
	columns: number;
	rows: number;
	fg: Rgb;
	bg: Rgb;
	cursor: TerminalCursor | null;
	lines: TextRun[][];
	/** Per viewport row: the part the terminal's selection covers, or null. */
	selection: (RowSelection | null)[];
	/** Scrollback rows above the viewport, and how far the viewport sits from the bottom. */
	scrollback: { total: number; offset: number; length: number };
}

export const PLAIN_STYLE: CellStyle = {
	fg: null,
	bg: null,
	bold: false,
	italic: false,
	faint: false,
	inverse: false,
	invisible: false,
	strikethrough: false,
	underline: false,
	overline: false,
	hyperlink: false,
};

export function sameStyle(a: CellStyle, b: CellStyle): boolean {
	return (
		a.fg === b.fg &&
		a.bg === b.bg &&
		a.bold === b.bold &&
		a.italic === b.italic &&
		a.faint === b.faint &&
		a.inverse === b.inverse &&
		a.invisible === b.invisible &&
		a.strikethrough === b.strikethrough &&
		a.underline === b.underline &&
		a.overline === b.overline &&
		a.hyperlink === b.hyperlink
	);
}

/**
 * A blank in this style still paints something: a background, a line through
 * it, or a link, which Ghostty underlines on hover over every cell it covers.
 */
export function paintsBlank(style: CellStyle): boolean {
	return style.bg !== null || style.inverse || style.underline || style.strikethrough || style.overline || style.hyperlink;
}

/**
 * Coalesces cells into runs and drops trailing blanks that draw nothing, so a
 * mostly empty row costs one short run. Only narrow cells merge.
 */
export class RunBuilder {
	private runs: TextRun[] = [];
	private column = 0;

	/** Every grid cell advances one column; a wide cell's second column is its spacer. */
	append(grapheme: string, width: 1 | 2, style: CellStyle): void {
		const last = this.runs.at(-1);
		if (
			width === 1 &&
			last &&
			last.columns === last.cells.length &&
			last.column + last.columns === this.column &&
			sameStyle(last.style, style)
		) {
			last.cells.push(grapheme);
			last.columns += 1;
		} else {
			this.runs.push({ column: this.column, cells: [grapheme], columns: width, style });
		}
		this.column += 1;
	}

	/** The spacer tail of a wide character: counts its column, draws nothing. */
	skip(): void {
		this.column += 1;
	}

	finish(): TextRun[] {
		while (this.runs.length > 0) {
			const last = this.runs[this.runs.length - 1];
			if (paintsBlank(last.style)) break;
			let blanks = 0;
			for (let i = last.cells.length - 1; i >= 0 && last.cells[i] === " "; i--) blanks++;
			if (blanks === 0) break;
			if (blanks === last.cells.length) {
				this.runs.pop();
				continue;
			}
			last.cells.length -= blanks;
			last.columns -= blanks;
			break;
		}
		const runs = this.runs;
		this.runs = [];
		this.column = 0;
		return runs;
	}
}

/** One row's text from `start` through `end` (inclusive), trimmed on the right. */
export function lineText(line: TextRun[], start = 0, end = Number.POSITIVE_INFINITY): string {
	let text = "";
	let column = 0;
	for (const run of line) {
		while (column < run.column) {
			if (column >= start && column <= end) text += " ";
			column++;
		}
		if (run.columns === 2 && run.cells.length === 1) {
			if (column >= start && column <= end) text += run.cells[0];
			column += 2;
			continue;
		}
		for (const cell of run.cells) {
			if (column >= start && column <= end) text += cell;
			column++;
		}
	}
	return text.replace(/\s+$/, "");
}

/** Plain text of a viewport range in reading order, one line per row. */
export function rangeText(
	snapshot: TerminalSnapshot,
	from: { row: number; column: number },
	to: { row: number; column: number },
): string {
	const [a, b] =
		from.row < to.row || (from.row === to.row && from.column <= to.column) ? [from, to] : [to, from];
	const out: string[] = [];
	for (let row = a.row; row <= b.row; row++) {
		const start = row === a.row ? a.column : 0;
		const end = row === b.row ? b.column : snapshot.columns - 1;
		out.push(lineText(snapshot.lines[row] ?? [], start, end));
	}
	return out.join("\n");
}

/** Every viewport row as text: what the accessibility mirror reads out. */
export function viewportText(snapshot: TerminalSnapshot): string {
	return snapshot.lines.map((line) => lineText(line)).join("\n").replace(/\n+$/, "");
}

/** The hyperlink run covering a cell, as a column range, or null. */
export function hyperlinkRunAt(
	snapshot: TerminalSnapshot,
	at: { row: number; column: number },
): RowSelection | null {
	for (const run of snapshot.lines[at.row] ?? []) {
		if (!run.style.hyperlink) continue;
		if (at.column >= run.column && at.column < run.column + run.columns) {
			return { start: run.column, end: run.column + run.columns - 1 };
		}
	}
	return null;
}
