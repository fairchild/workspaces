/*
 * Paints a TerminalSnapshot on a canvas cell grid, following the mobile
 * TerminalScreenView: every glyph sits at column × cell width, so
 * fallback-font glyphs cannot push a line out of alignment; adjacent
 * backgrounds merge into one rect; light box drawing is stroked as geometry
 * so borders join. The selection, cursor shape and blink phase, a hovered
 * hyperlink and an IME preedit layer on top. The cell rules are pure and tested.
 */
import { type CellStyle, PLAIN_STYLE, type Rgb, type RowSelection, type TerminalSnapshot } from "./snapshot";

export interface PaintedCell {
	row: number;
	column: number;
	width: number;
	text: string;
	fg: Rgb;
	faint: boolean;
	/** null leaves the screen background showing. */
	bg: Rgb | null;
	bold: boolean;
	italic: boolean;
	underline: boolean;
	strikethrough: boolean;
	overline: boolean;
}

export interface PaintOptions {
	focused: boolean;
	/** The blink phase: false hides a blinking cursor for this frame. */
	blinkOn: boolean;
	cursorColor: Rgb;
	selectionColor: string;
	/** The hyperlink under the pointer, underlined while hovered. */
	hoveredLink: (RowSelection & { row: number }) | null;
	/** IME composition text laid out from the cursor, drawn over the grid. */
	preedit: { text: string; width: number }[] | null;
}

export type CursorKind = "block" | "bar" | "underline" | "hollow";

/**
 * How the cursor draws this frame: its program-set shape while focused, a
 * hollow box while not, nothing in the off phase of a blink or when hidden.
 */
export function cursorKind(snapshot: TerminalSnapshot, focused: boolean, blinkOn: boolean): CursorKind | null {
	const cursor = snapshot.cursor;
	if (!cursor) return null;
	if (!focused) return "hollow";
	if (cursor.blinking && !blinkOn) return null;
	return cursor.shape === "block_hollow" ? "hollow" : cursor.shape;
}

export function paintedCells(snapshot: TerminalSnapshot, cursorBlock: boolean): PaintedCell[] {
	const cells: PaintedCell[] = [];
	const cursor = snapshot.cursor;
	snapshot.lines.forEach((line, row) => {
		for (const run of line) {
			const wide = run.columns === 2 && run.cells.length === 1;
			run.cells.forEach((text, i) => {
				const column = run.column + i;
				const width = wide ? 2 : 1;
				const onCursor =
					cursorBlock && cursor !== null && cursor.row === row &&
					(cursor.column === column || (wide && cursor.column === column + 1));
				cells.push(paint(snapshot, text, row, column, width, run.style, onCursor));
			});
		}
	});
	if (cursorBlock && cursor && !cells.some((c) => c.row === cursor.row && c.column <= cursor.column && cursor.column < c.column + c.width)) {
		cells.push(paint(snapshot, " ", cursor.row, cursor.wide ? cursor.column - 1 : cursor.column, cursor.wide ? 2 : 1, BLANK, true));
	}
	return cells;
}

const BLANK: CellStyle = PLAIN_STYLE;

function paint(
	snapshot: TerminalSnapshot,
	text: string,
	row: number,
	column: number,
	width: number,
	style: CellStyle,
	onCursor: boolean,
): PaintedCell {
	let fg = style.fg ?? snapshot.fg;
	let bg = style.bg;
	if (style.inverse !== onCursor) [fg, bg] = [bg ?? snapshot.bg, fg];
	if (style.invisible) fg = bg ?? snapshot.bg;
	return {
		row,
		column,
		width,
		text,
		fg,
		faint: style.faint,
		bg,
		bold: style.bold,
		italic: style.italic,
		underline: style.underline,
		strikethrough: style.strikethrough,
		overline: style.overline,
	};
}

export interface BackgroundSpan {
	row: number;
	column: number;
	width: number;
	color: Rgb;
}

/** Adjacent same-colored backgrounds as one rect, so fills leave no hairline seams. */
export function backgroundSpans(cells: PaintedCell[]): BackgroundSpan[] {
	const spans: BackgroundSpan[] = [];
	for (const cell of cells) {
		if (cell.bg === null) continue;
		const last = spans.at(-1);
		if (last && last.row === cell.row && last.color === cell.bg && last.column + last.width === cell.column) {
			last.width += cell.width;
		} else {
			spans.push({ row: cell.row, column: cell.column, width: cell.width, color: cell.bg });
		}
	}
	return spans;
}

/**
 * The preedit as cells from the cursor onward, in the default colors and
 * underlined the way a native composition is. Clipped at the right edge.
 */
export function preeditCells(snapshot: TerminalSnapshot, graphemes: { text: string; width: number }[]): PaintedCell[] {
	const cursor = snapshot.cursor;
	if (!cursor || graphemes.length === 0) return [];
	const cells: PaintedCell[] = [];
	let column = cursor.column - (cursor.wide ? 1 : 0);
	for (const { text, width } of graphemes) {
		const w = Math.max(1, width);
		if (column + w > snapshot.columns) break;
		cells.push({ ...paint(snapshot, text, cursor.row, column, w, BLANK, false), bg: snapshot.bg, underline: true });
		column += w;
	}
	return cells;
}

/** Edges a light box-drawing character joins: left, right, up, down; rounded corners arc. */
const BOX: Record<string, { l?: 1; r?: 1; u?: 1; d?: 1; round?: 1 }> = {
	"─": { l: 1, r: 1 },
	"│": { u: 1, d: 1 },
	"┌": { r: 1, d: 1 },
	"┐": { l: 1, d: 1 },
	"└": { r: 1, u: 1 },
	"┘": { l: 1, u: 1 },
	"├": { u: 1, d: 1, r: 1 },
	"┤": { u: 1, d: 1, l: 1 },
	"┬": { l: 1, r: 1, d: 1 },
	"┴": { l: 1, r: 1, u: 1 },
	"┼": { l: 1, r: 1, u: 1, d: 1 },
	"╭": { r: 1, d: 1, round: 1 },
	"╮": { l: 1, d: 1, round: 1 },
	"╰": { r: 1, u: 1, round: 1 },
	"╯": { l: 1, u: 1, round: 1 },
};

export interface CellMetrics {
	width: number;
	height: number;
	baseline: number;
	fontSize: number;
	fontFamily: string;
}

export function measureCell(ctx: CanvasRenderingContext2D, fontSize: number, fontFamily: string): CellMetrics {
	ctx.font = `${fontSize}px ${fontFamily}`;
	const m = ctx.measureText("M");
	const ascent = m.fontBoundingBoxAscent || fontSize * 0.8;
	const descent = m.fontBoundingBoxDescent || fontSize * 0.2;
	const height = Math.ceil(ascent + descent);
	return {
		width: m.width,
		height,
		baseline: Math.round((height - (ascent + descent)) / 2 + ascent),
		fontSize,
		fontFamily,
	};
}

const css = (rgb: Rgb) => `#${rgb.toString(16).padStart(6, "0")}`;

export function paintSnapshot(
	ctx: CanvasRenderingContext2D,
	snapshot: TerminalSnapshot,
	cell: CellMetrics,
	options: PaintOptions,
): void {
	const { width: cw, height: ch } = cell;
	ctx.fillStyle = css(snapshot.bg);
	ctx.fillRect(0, 0, ctx.canvas.width, ctx.canvas.height);

	const kind = cursorKind(snapshot, options.focused, options.blinkOn);
	const cells = paintedCells(snapshot, kind === "block" && !options.preedit);
	for (const span of backgroundSpans(cells)) {
		ctx.fillStyle = css(span.color);
		ctx.fillRect(Math.floor(span.column * cw), span.row * ch, Math.ceil(span.width * cw), ch);
	}

	ctx.fillStyle = options.selectionColor;
	snapshot.selection.forEach((range, row) => {
		if (range) ctx.fillRect(range.start * cw, row * ch, (range.end - range.start + 1) * cw, ch);
	});

	ctx.textBaseline = "alphabetic";
	const glyphs = paintGlyphs(ctx, cell);
	glyphs(cells);
	const link = options.hoveredLink;
	if (link) {
		const fg = cells.find((c) => c.row === link.row && c.column >= link.start)?.fg ?? snapshot.fg;
		ctx.fillStyle = css(fg);
		ctx.fillRect(link.start * cw, link.row * ch + cell.baseline + 2, (link.end - link.start + 1) * cw, 1);
	}

	const cursor = snapshot.cursor;
	if (options.preedit && cursor) {
		const preedit = preeditCells(snapshot, options.preedit);
		for (const c of preedit) {
			ctx.fillStyle = css(snapshot.bg);
			ctx.fillRect(Math.floor(c.column * cw), c.row * ch, Math.ceil(c.width * cw), ch);
		}
		glyphs(preedit);
		const end = preedit.at(-1);
		if (end) {
			ctx.fillStyle = css(options.cursorColor);
			ctx.fillRect((end.column + end.width) * cw, end.row * ch, Math.max(1, Math.round(cw / 8)), ch);
		}
		return;
	}
	if (!cursor || !kind || kind === "block") return;
	const x = (cursor.wide ? cursor.column - 1 : cursor.column) * cw;
	const y = cursor.row * ch;
	const width = (cursor.wide ? 2 : 1) * cw;
	const thickness = Math.max(1, Math.round(cw / 8));
	ctx.fillStyle = css(options.cursorColor);
	ctx.strokeStyle = css(options.cursorColor);
	if (kind === "bar") ctx.fillRect(x, y, thickness, ch);
	else if (kind === "underline") ctx.fillRect(x, y + ch - thickness, width, thickness);
	else {
		ctx.lineWidth = 1;
		ctx.strokeRect(x + 0.5, y + 0.5, width - 1, ch - 1);
	}
}

/** Draws glyphs and their decorations for a list of cells, reusing the font between cells. */
function paintGlyphs(ctx: CanvasRenderingContext2D, cell: CellMetrics) {
	const { width: cw, height: ch } = cell;
	let font = "";
	return (cells: PaintedCell[]) => {
		for (const c of cells) {
			if (c.text === " " && !c.underline && !c.strikethrough && !c.overline) continue;
			const x = c.column * cw;
			const y = c.row * ch;
			ctx.fillStyle = css(c.fg);
			ctx.globalAlpha = c.faint ? 0.6 : 1;
			const box = BOX[c.text];
			if (box) {
				strokeBox(ctx, box, x, y, cw, ch, c.bold ? 2 : 1, css(c.fg));
			} else if (c.text !== " ") {
				const next = `${c.italic ? "italic " : ""}${c.bold ? "bold " : ""}${cell.fontSize}px ${cell.fontFamily}`;
				if (next !== font) ctx.font = font = next;
				const glyphWidth = ctx.measureText(c.text).width;
				const slot = c.width * cw;
				const scale = glyphWidth > slot ? slot / glyphWidth : 1;
				if (scale < 1) {
					ctx.save();
					ctx.translate(x, y + cell.baseline);
					ctx.scale(scale, 1);
					ctx.fillText(c.text, 0, 0);
					ctx.restore();
				} else {
					ctx.fillText(c.text, x + (slot - glyphWidth) / 2, y + cell.baseline);
				}
			}
			if (c.underline) ctx.fillRect(x, y + cell.baseline + 2, c.width * cw, 1);
			if (c.strikethrough) ctx.fillRect(x, y + Math.round(ch / 2), c.width * cw, 1);
			if (c.overline) ctx.fillRect(x, y, c.width * cw, 1);
		}
		ctx.globalAlpha = 1;
	};
}

function strokeBox(
	ctx: CanvasRenderingContext2D,
	box: (typeof BOX)[string],
	x: number,
	y: number,
	w: number,
	h: number,
	thickness: number,
	color: string,
) {
	const cx = Math.round(x + w / 2) - thickness / 2;
	const cy = Math.round(y + h / 2) - thickness / 2;
	if (box.round) {
		ctx.strokeStyle = color;
		ctx.lineWidth = thickness;
		ctx.beginPath();
		const mx = cx + thickness / 2;
		const my = cy + thickness / 2;
		const ex = box.r ? x + w : x;
		const ey = box.d ? y + h : y;
		const r = Math.min(w, h) / 2;
		ctx.moveTo(ex, my);
		ctx.arcTo(mx, my, mx, ey, r);
		ctx.lineTo(mx, ey);
		ctx.stroke();
		return;
	}
	// Cell widths are fractional; whole-pixel ends keep neighbors from leaving anti-aliased seams.
	const left = Math.floor(x);
	const right = Math.ceil(x + w);
	if (box.l) ctx.fillRect(left, cy, cx - left + thickness, thickness);
	if (box.r) ctx.fillRect(cx, cy, right - cx, thickness);
	if (box.u) ctx.fillRect(cx, y, thickness, cy - y + thickness);
	if (box.d) ctx.fillRect(cx, cy, thickness, y + h - cy);
}
