/*
 * The front end ghostty-web would otherwise provide, owned here for the #1846
 * spike: a canvas that paints VtTerminal snapshots once per animation frame,
 * and a hidden textarea that turns keys, IME composition and paste into the
 * bytes Ghostty's encoders produce. Selection is a viewport rectangle in JS;
 * wheel scrolls Ghostty's scrollback; a ResizeObserver keeps the grid fitted.
 */
import { loadGhosttyVt, type VtBuild, VtTerminal } from "./ghostty-vt";
import { type CellMetrics, measureCell, paintSnapshot, type Selection } from "./paint";
import { type Rgb, selectionText, type TerminalSnapshot } from "./snapshot";

export interface CanvasTerminalTheme {
	background: string;
	foreground: string;
	cursor: string;
	selectionBackground: string;
	black: string;
	red: string;
	green: string;
	yellow: string;
	blue: string;
	magenta: string;
	cyan: string;
	white: string;
}

export interface CanvasTerminalOptions {
	build?: VtBuild;
	fontSize?: number;
	fontFamily?: string;
	theme: CanvasTerminalTheme;
	onData: (bytes: Uint8Array) => void;
	onResize?: (columns: number, rows: number) => void;
}

export interface FrameStat {
	snapshotMs: number;
	paintMs: number;
}

const MODS = { shift: 1, ctrl: 2, alt: 4, super: 8 } as const;

const hex = (value: string): Rgb => Number.parseInt(value.replace("#", "").slice(0, 6), 16);

/** W3C KeyboardEvent.code → GhosttyKey name: KeyA → A, ArrowUp → ARROW_UP, Digit1 → DIGIT_1. */
export function ghosttyKeyName(code: string): string {
	if (/^F\d+$/.test(code)) return code;
	return code
		.replace(/^Key(?=[A-Z]$)/, "")
		.replace(/([a-z])([A-Z0-9])/g, "$1_$2")
		.toUpperCase();
}

const UNSHIFTED: Record<string, string> = {
	Backquote: "`",
	Minus: "-",
	Equal: "=",
	BracketLeft: "[",
	BracketRight: "]",
	Backslash: "\\",
	Semicolon: ";",
	Quote: "'",
	Comma: ",",
	Period: ".",
	Slash: "/",
	Space: " ",
};

function unshiftedCodepoint(event: KeyboardEvent): number {
	const { code, key } = event;
	if (/^Key[A-Z]$/.test(code)) return code.charCodeAt(3) + 32;
	if (/^Digit\d$/.test(code)) return code.charCodeAt(5);
	if (UNSHIFTED[code]) return UNSHIFTED[code].codePointAt(0)!;
	return [...key].length === 1 ? key.codePointAt(0)! : 0;
}

export class CanvasTerminal {
	readonly canvas: HTMLCanvasElement;
	readonly textarea: HTMLTextAreaElement;
	readonly frames: FrameStat[] = [];
	terminal!: VtTerminal;
	version = "";

	private readonly host: HTMLElement;
	private readonly options: CanvasTerminalOptions;
	private ctx!: CanvasRenderingContext2D;
	private cell!: CellMetrics;
	private snapshot: TerminalSnapshot | null = null;
	private selection: Selection | null = null;
	private dragging = false;
	private focused = false;
	private composing = false;
	private frameRequested = false;
	private wheelRemainder = 0;
	private keyCodes = new Map<string, number>();
	private observer: ResizeObserver | null = null;
	private disposed = false;
	private readonly cleanups: (() => void)[] = [];

	constructor(host: HTMLElement, options: CanvasTerminalOptions) {
		this.host = host;
		this.options = options;
		this.canvas = document.createElement("canvas");
		this.canvas.style.cssText = "display:block;width:100%;height:100%;cursor:text";
		this.textarea = document.createElement("textarea");
		this.textarea.setAttribute("aria-label", "Terminal input");
		this.textarea.autocapitalize = "off";
		this.textarea.spellcheck = false;
		this.textarea.style.cssText =
			"position:absolute;left:0;top:0;width:1px;height:1em;opacity:0;padding:0;border:0;resize:none;overflow:hidden;white-space:pre";
	}

	async open(): Promise<void> {
		const vtModule = await loadGhosttyVt(this.options.build);
		if (this.disposed) return;
		this.version = vtModule.version;
		const values = (vtModule.layout.types.GhosttyKey as { values: Record<string, number> }).values;
		for (const [name, value] of Object.entries(values)) this.keyCodes.set(name, value);

		this.host.style.position ||= "relative";
		this.host.append(this.canvas, this.textarea);
		this.ctx = this.canvas.getContext("2d", { alpha: false })!;
		const fontSize = this.options.fontSize ?? 13;
		const fontFamily = this.options.fontFamily ?? 'ui-monospace, "SF Mono", Menlo, monospace';
		this.cell = measureCell(this.ctx, fontSize, fontFamily);
		const { columns, rows } = this.fit();
		const t = this.options.theme;
		this.terminal = new VtTerminal(vtModule, {
			columns,
			rows,
			fg: hex(t.foreground),
			bg: hex(t.background),
			palette: {
				0: hex(t.black),
				1: hex(t.red),
				2: hex(t.green),
				3: hex(t.yellow),
				4: hex(t.blue),
				5: hex(t.magenta),
				6: hex(t.cyan),
				7: hex(t.white),
			},
			onReply: (bytes) => this.options.onData(bytes),
		});
		this.sizeCanvas();
		this.bind();
		this.observer = new ResizeObserver(() => this.onHostResize());
		this.observer.observe(this.host);
		this.requestFrame();
	}

	get columns(): number {
		return this.terminal?.columns ?? 0;
	}
	get rows(): number {
		return this.terminal?.rows ?? 0;
	}

	write(data: Uint8Array | string): void {
		if (!this.terminal) return;
		this.terminal.write(data);
		this.requestFrame();
	}

	focus(): void {
		this.textarea.focus({ preventScroll: true });
	}
	blur(): void {
		this.textarea.blur();
	}

	/** Viewport text, for tests and screen-reader mirrors. */
	text(): string {
		const s = this.snapshot ?? this.terminal.snapshot();
		return selectionText(s, { row: 0, column: 0 }, { row: s.rows - 1, column: s.columns - 1 });
	}

	dispose(): void {
		this.disposed = true;
		this.observer?.disconnect();
		for (const cleanup of this.cleanups) cleanup();
		this.terminal?.dispose();
		this.canvas.remove();
		this.textarea.remove();
	}

	private fit(): { columns: number; rows: number } {
		const style = getComputedStyle(this.host);
		const width = this.host.clientWidth - Number.parseFloat(style.paddingLeft) - Number.parseFloat(style.paddingRight);
		const height = this.host.clientHeight - Number.parseFloat(style.paddingTop) - Number.parseFloat(style.paddingBottom);
		return {
			columns: Math.max(2, Math.floor(width / this.cell.width)),
			rows: Math.max(1, Math.floor(height / this.cell.height)),
		};
	}

	private sizeCanvas(): void {
		const dpr = window.devicePixelRatio || 1;
		const width = this.terminal.columns * this.cell.width;
		const height = this.terminal.rows * this.cell.height;
		this.canvas.style.width = `${width}px`;
		this.canvas.style.height = `${height}px`;
		this.canvas.width = Math.ceil(width * dpr);
		this.canvas.height = Math.ceil(height * dpr);
		this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
	}

	private onHostResize(): void {
		const { columns, rows } = this.fit();
		if (columns === this.terminal.columns && rows === this.terminal.rows) return;
		this.terminal.resize(columns, rows, this.cell.width, this.cell.height);
		this.sizeCanvas();
		this.selection = null;
		this.options.onResize?.(columns, rows);
		this.requestFrame();
	}

	private requestFrame(): void {
		if (this.frameRequested || this.disposed) return;
		this.frameRequested = true;
		requestAnimationFrame(() => {
			this.frameRequested = false;
			if (this.disposed) return;
			const t0 = performance.now();
			const snapshot = this.terminal.snapshot();
			const t1 = performance.now();
			this.snapshot = snapshot;
			paintSnapshot(this.ctx, snapshot, this.cell, {
				focused: this.focused,
				cursorColor: hex(this.options.theme.cursor),
				selection: this.selection,
				selectionColor: this.options.theme.selectionBackground,
			});
			const t2 = performance.now();
			this.frames.push({ snapshotMs: t1 - t0, paintMs: t2 - t1 });
			if (this.frames.length > 5000) this.frames.splice(0, this.frames.length - 5000);
			if (snapshot.cursor) {
				this.textarea.style.transform = `translate(${snapshot.cursor.column * this.cell.width}px, ${snapshot.cursor.row * this.cell.height}px)`;
			}
		});
	}

	private send(bytes: Uint8Array): void {
		if (bytes.length === 0) return;
		this.selection = null;
		if (this.snapshot && this.snapshot.scrollback.offset + this.snapshot.scrollback.length < this.snapshot.scrollback.total) {
			this.terminal.scrollToBottom();
		}
		this.options.onData(bytes);
		this.requestFrame();
	}

	private listen<K extends keyof HTMLElementEventMap>(
		target: HTMLElement | Window,
		type: K,
		handler: (event: HTMLElementEventMap[K]) => void,
		options?: AddEventListenerOptions,
	): void {
		target.addEventListener(type, handler as EventListener, options);
		this.cleanups.push(() => target.removeEventListener(type, handler as EventListener, options));
	}

	private bind(): void {
		const ta = this.textarea;
		const encoder = new TextEncoder();
		this.listen(ta, "focus", () => {
			this.focused = true;
			this.requestFrame();
		});
		this.listen(ta, "blur", () => {
			this.focused = false;
			this.requestFrame();
		});
		this.listen(ta, "keydown", (event) => this.onKeyDown(event));
		this.listen(ta, "compositionstart", () => {
			this.composing = true;
		});
		this.listen(ta, "compositionend", (event) => {
			this.composing = false;
			if (event.data) this.send(encoder.encode(event.data));
			ta.value = "";
		});
		this.listen(ta, "input", (event) => {
			const input = event as InputEvent;
			if (this.composing || input.isComposing) return;
			if (input.inputType === "insertText" && input.data) this.send(encoder.encode(input.data));
			ta.value = "";
		});
		this.listen(ta, "paste", (event) => {
			event.preventDefault();
			const text = event.clipboardData?.getData("text/plain");
			if (text) this.send(this.terminal.encodePaste(text));
		});
		this.listen(ta, "copy", (event) => {
			const text = this.selectedText();
			if (!text) return;
			event.preventDefault();
			event.clipboardData?.setData("text/plain", text);
		});
		this.listen(this.canvas, "mousedown", (event) => {
			event.preventDefault();
			this.focus();
			const at = this.cellAt(event);
			if (event.detail === 2) {
				this.selection = this.wordAt(at);
			} else {
				this.selection = { from: at, to: at };
				this.dragging = true;
			}
			this.requestFrame();
		});
		this.listen(window, "mousemove", (event) => {
			if (!this.dragging || !this.selection) return;
			this.selection = { from: this.selection.from, to: this.cellAt(event) };
			this.requestFrame();
		});
		this.listen(window, "mouseup", () => {
			if (!this.dragging) return;
			this.dragging = false;
			const s = this.selection;
			if (s && s.from.row === s.to.row && s.from.column === s.to.column) this.selection = null;
			this.requestFrame();
		});
		this.listen(
			this.canvas,
			"wheel",
			(event) => {
				event.preventDefault();
				const pixels = event.deltaMode === 1 ? event.deltaY * this.cell.height : event.deltaY;
				this.wheelRemainder += pixels;
				const rows = Math.trunc(this.wheelRemainder / this.cell.height);
				if (rows === 0) return;
				this.wheelRemainder -= rows * this.cell.height;
				this.terminal.scrollViewport(rows);
				this.requestFrame();
			},
			{ passive: false },
		);
	}

	private onKeyDown(event: KeyboardEvent): void {
		if (event.isComposing || event.keyCode === 229 || event.key === "Dead") return;
		const mac = navigator.platform.startsWith("Mac");
		if (event.metaKey && mac) {
			// Cmd shortcuts stay the browser's: copy, paste, select-all, tab switching.
			return;
		}
		if (event.ctrlKey && event.shiftKey && (event.code === "KeyC" || event.code === "KeyV")) return;
		const key = this.keyCodes.get(ghosttyKeyName(event.code)) ?? 0;
		const mods =
			(event.shiftKey ? MODS.shift : 0) |
			(event.ctrlKey ? MODS.ctrl : 0) |
			(event.altKey ? MODS.alt : 0) |
			(event.metaKey ? MODS.super : 0);
		const text = [...event.key].length === 1 ? event.key : undefined;
		const bytes = this.terminal.encodeKey({
			key,
			mods,
			text,
			unshiftedCodepoint: unshiftedCodepoint(event),
			repeat: event.repeat,
		});
		if (bytes.length === 0) return;
		event.preventDefault();
		this.send(bytes);
	}

	private cellAt(event: MouseEvent): { row: number; column: number } {
		const rect = this.canvas.getBoundingClientRect();
		return {
			column: Math.min(this.terminal.columns - 1, Math.max(0, Math.floor((event.clientX - rect.left) / this.cell.width))),
			row: Math.min(this.terminal.rows - 1, Math.max(0, Math.floor((event.clientY - rect.top) / this.cell.height))),
		};
	}

	private wordAt(at: { row: number; column: number }): Selection | null {
		if (!this.snapshot) return null;
		const line = selectionText(this.snapshot, { row: at.row, column: 0 }, { row: at.row, column: this.snapshot.columns - 1 });
		const chars = [...line.padEnd(this.snapshot.columns)];
		if (/\s/.test(chars[at.column] ?? " ")) return null;
		let start = at.column;
		let end = at.column;
		while (start > 0 && !/\s/.test(chars[start - 1])) start--;
		while (end < chars.length - 1 && !/\s/.test(chars[end + 1])) end++;
		return { from: { row: at.row, column: start }, to: { row: at.row, column: end } };
	}

	private selectedText(): string {
		if (!this.selection || !this.snapshot) return "";
		return selectionText(this.snapshot, this.selection.from, this.selection.to);
	}
}
