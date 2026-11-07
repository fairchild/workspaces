/*
 * The screen as plain values (#1846 spike), the web twin of the mobile
 * package's TerminalSnapshot: lines of styled runs on a fixed cell grid, the
 * cursor, and the default colors. A run is either narrow cells (one grapheme
 * per column) or a single wide cell, so the painter places glyphs on the grid
 * without measuring them. RunBuilder coalesces a row's cells into runs.
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

export interface TerminalCursor {
	column: number;
	row: number;
	/** The cursor sits on a wide character. */
	wide: boolean;
}

export interface TerminalSnapshot {
	columns: number;
	rows: number;
	fg: Rgb;
	bg: Rgb;
	cursor: TerminalCursor | null;
	lines: TextRun[][];
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
		a.overline === b.overline
	);
}

/** A blank in this style still paints something: a background, or a line through it. */
export function paintsBlank(style: CellStyle): boolean {
	return style.bg !== null || style.inverse || style.underline || style.strikethrough || style.overline;
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

	/** A spacer cell (the tail of a wide character, or a wrapped wide head): counts its column, draws nothing. */
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

/** Plain text of a viewport rectangle, for copy. Rows are trimmed on the right. */
export function selectionText(
	snapshot: TerminalSnapshot,
	from: { row: number; column: number },
	to: { row: number; column: number },
): string {
	const [a, b] =
		from.row < to.row || (from.row === to.row && from.column <= to.column)
			? [from, to]
			: [to, from];
	const out: string[] = [];
	for (let row = a.row; row <= b.row; row++) {
		const line = snapshot.lines[row] ?? [];
		const start = row === a.row ? a.column : 0;
		const end = row === b.row ? b.column : snapshot.columns - 1;
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
		out.push(text.replace(/\s+$/, ""));
	}
	return out.join("\n");
}
