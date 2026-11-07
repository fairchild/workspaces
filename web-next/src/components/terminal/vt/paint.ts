/*
 * Paints a TerminalSnapshot on a canvas cell grid (#1846 spike), following
 * the mobile TerminalScreenView: every glyph sits at column × cell width, so
 * fallback-font glyphs cannot push a line out of alignment; adjacent
 * backgrounds merge into one rect; light box drawing is stroked as geometry
 * so borders join. paintedCells and backgroundSpans are pure and tested.
 */
import type { CellStyle, Rgb, TerminalSnapshot } from "./snapshot";

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
}

export interface Selection {
	from: { row: number; column: number };
	to: { row: number; column: number };
}

export interface PaintOptions {
	focused: boolean;
	cursorColor: Rgb;
	selection: Selection | null;
	selectionColor: string;
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
		cells.push(paint(snapshot, " ", cursor.row, cursor.column, cursor.wide ? 2 : 1, BLANK, true));
	}
	return cells;
}

const BLANK: CellStyle = {
	fg: null,
	bg: null,
	bold: false,
	italic: false,
	faint: false,
	inverse: false,
	invisible: false,
	strikethrough: false,
	underline: false,
};

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

	const cells = paintedCells(snapshot, options.focused);
	for (const span of backgroundSpans(cells)) {
		ctx.fillStyle = css(span.color);
		ctx.fillRect(Math.floor(span.column * cw), span.row * ch, Math.ceil(span.width * cw), ch);
	}

	if (options.selection) {
		ctx.fillStyle = options.selectionColor;
		const { from, to } = orderSelection(options.selection);
		for (let row = from.row; row <= to.row; row++) {
			const start = row === from.row ? from.column : 0;
			const end = row === to.row ? to.column : snapshot.columns - 1;
			ctx.fillRect(start * cw, row * ch, (end - start + 1) * cw, ch);
		}
	}

	ctx.textBaseline = "alphabetic";
	let font = "";
	for (const c of cells) {
		if (c.text === " " && !c.underline && !c.strikethrough) continue;
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
	}
	ctx.globalAlpha = 1;

	const cursor = snapshot.cursor;
	if (cursor && !options.focused) {
		ctx.strokeStyle = css(options.cursorColor);
		ctx.lineWidth = 1;
		ctx.strokeRect(cursor.column * cw + 0.5, cursor.row * ch + 0.5, (cursor.wide ? 2 : 1) * cw - 1, ch - 1);
	}
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

export function orderSelection(selection: Selection): Selection {
	const { from, to } = selection;
	return from.row < to.row || (from.row === to.row && from.column <= to.column)
		? selection
		: { from: to, to: from };
}
