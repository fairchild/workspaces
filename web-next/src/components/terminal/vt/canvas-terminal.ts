/*
 * The terminal front end ghostty-web would otherwise provide: a canvas that
 * paints VtTerminal snapshots once per animation frame, a hidden textarea
 * that turns keys, IME composition and paste into the bytes Ghostty's
 * encoders produce, and a screen-reader mirror of the viewport text. Pointer
 * input goes to the program as mouse reports when it asked for them, and to
 * Ghostty's selection gestures otherwise; wheel scrolls Ghostty's scrollback.
 */
import { loadGhosttyVt, type MouseButton, type PointerAt, type SurfaceGeometry, VtTerminal } from "./ghostty-vt";
import { type CellMetrics, measureCell, paintSnapshot } from "./paint";
import { hyperlinkRunAt, type RowSelection, type Rgb, type TerminalSnapshot, viewportText } from "./snapshot";

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

/**
 * Whether macOS Option sends Alt (an ESC prefix, so Option+B moves a shell
 * back a word) or composes a character (Option+B types ∫). Ghostty's
 * `macos-option-as-alt` values; "left" and "right" pick one Option key.
 */
export type MacOptionAsAlt = "false" | "true" | "left" | "right";

export interface CanvasTerminalOptions {
	fontSize?: number;
	fontFamily?: string;
	theme: CanvasTerminalTheme;
	onData: (bytes: Uint8Array) => void;
	onResize?: (columns: number, rows: number) => void;
	/** Defaults to "false", Ghostty's default, which the desktop app inherits. */
	macOptionAsAlt?: MacOptionAsAlt;
	/** Opens a Cmd/Ctrl-clicked OSC 8 link; defaults to a new tab for http, https and mailto. */
	onOpenLink?: (uri: string) => void;
}

export interface FrameStat {
	snapshotMs: number;
	paintMs: number;
}

/** GhosttyMods bits, frozen by the 1.0 ABI. */
export const MODS = { shift: 1, ctrl: 2, alt: 4, super: 8, altRight: 1 << 8 } as const;

const BLINK_MS = 600;
const AUTOSCROLL_MS = 50;
const MIRROR_DELAY_MS = 250;

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

/** The character a physical key types with no modifiers, from its US-layout code. */
function physicalCharacter(code: string): string | undefined {
	if (/^Key[A-Z]$/.test(code)) return code[3].toLowerCase();
	if (/^Digit\d$/.test(code)) return code[5];
	return UNSHIFTED[code];
}

type KeyFields = Pick<KeyboardEvent, "key" | "code" | "shiftKey" | "ctrlKey" | "altKey" | "metaKey">;

export interface KeyInput {
	mods: number;
	text: string | undefined;
	unshiftedCodepoint: number;
}

/**
 * What a key press asks the encoder for, with the macOS Option policy applied.
 * Option acting as Alt keeps the Alt modifier and swaps the composed character
 * (∫) for the key's own (b), so the encoder emits ESC b; Option composing drops
 * Alt from a key that typed text and passes that text through, but keeps it on
 * keys that type nothing (Option+Left stays ESC[1;3D, as in Ghostty). Elsewhere
 * Alt is always Alt.
 * Returns null for a dead key Option is composing, which the IME finishes.
 */
export function keyInput(
	event: KeyFields,
	platform: { mac: boolean; optionAsAlt: MacOptionAsAlt; altSide: "left" | "right" | null },
): KeyInput | null {
	const physical = physicalCharacter(event.code);
	let mods =
		(event.shiftKey ? MODS.shift : 0) |
		(event.ctrlKey ? MODS.ctrl : 0) |
		(event.altKey ? MODS.alt : 0) |
		(event.metaKey ? MODS.super : 0);
	if (event.altKey && platform.altSide === "right") mods |= MODS.altRight;
	let text = [...event.key].length === 1 ? event.key : undefined;
	if (platform.mac && event.altKey) {
		const { optionAsAlt, altSide } = platform;
		const optionIsAlt = optionAsAlt === "true" || (altSide !== null && optionAsAlt === altSide);
		if (optionIsAlt) {
			if (physical) text = event.shiftKey && /[a-z]/.test(physical) ? physical.toUpperCase() : physical;
		} else {
			if (event.key === "Dead") return null;
			if (text !== undefined) mods &= ~(MODS.alt | MODS.altRight);
		}
	} else if (event.key === "Dead") {
		return null;
	}
	const unshifted = physical ?? ([...event.key].length === 1 ? event.key : "");
	return { mods, text, unshiftedCodepoint: unshifted ? unshifted.codePointAt(0)! : 0 };
}

const DOM_BUTTONS: Record<number, MouseButton> = { 0: "left", 1: "middle", 2: "right" };

function defaultOpenLink(uri: string): void {
	let url: URL;
	try {
		url = new URL(uri);
	} catch {
		return;
	}
	if (!["http:", "https:", "mailto:"].includes(url.protocol)) return;
	window.open(url.href, "_blank", "noopener,noreferrer");
}

export class CanvasTerminal {
	readonly canvas: HTMLCanvasElement;
	readonly textarea: HTMLTextAreaElement;
	/** Visually hidden plain text of the viewport, for screen readers and tests. */
	readonly mirror: HTMLDivElement;
	readonly frames: FrameStat[] = [];
	terminal!: VtTerminal;
	version = "";

	private readonly host: HTMLElement;
	private readonly options: CanvasTerminalOptions;
	private readonly mac: boolean;
	private ctx!: CanvasRenderingContext2D;
	private cell!: CellMetrics;
	private snapshot: TerminalSnapshot | null = null;
	private focused = false;
	private composing = false;
	private preedit: { text: string; width: number }[] | null = null;
	private blinkOn = true;
	private blinkTimer: ReturnType<typeof setInterval> | null = null;
	private selecting = false;
	private pointer: PointerAt | null = null;
	private autoscrollTimer: ReturnType<typeof setInterval> | null = null;
	private reportedButtons = new Set<MouseButton>();
	private hoveredLink: (RowSelection & { row: number }) | null = null;
	private altSide: "left" | "right" | null = null;
	private mirrorTimer: ReturnType<typeof setTimeout> | null = null;
	private frameRequested = false;
	private wheelRemainder = 0;
	private keyCodes = new Map<string, number>();
	private observer: ResizeObserver | null = null;
	private disposed = false;
	private readonly cleanups: (() => void)[] = [];

	constructor(host: HTMLElement, options: CanvasTerminalOptions) {
		this.host = host;
		this.options = options;
		this.mac = typeof navigator !== "undefined" && /^Mac|iPhone|iPad/.test(navigator.platform);
		this.canvas = document.createElement("canvas");
		this.canvas.style.cssText = "display:block;width:100%;height:100%;cursor:text";
		this.canvas.setAttribute("aria-hidden", "true");
		this.textarea = document.createElement("textarea");
		this.textarea.setAttribute("aria-label", "Terminal input");
		this.textarea.autocapitalize = "off";
		this.textarea.spellcheck = false;
		this.textarea.style.cssText =
			"position:absolute;left:0;top:0;width:1px;height:1em;opacity:0;padding:0;border:0;resize:none;overflow:hidden;white-space:pre";
		this.mirror = document.createElement("div");
		this.mirror.setAttribute("role", "document");
		this.mirror.setAttribute("aria-label", "Terminal screen");
		this.mirror.setAttribute("aria-live", "off");
		this.mirror.dataset.terminalMirror = "";
		this.mirror.style.cssText =
			"position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:pre;border:0";
	}

	async open(): Promise<void> {
		const vtModule = await loadGhosttyVt();
		if (this.disposed) return;
		this.version = vtModule.version;
		const values = (vtModule.layout.types.GhosttyKey as { values: Record<string, number> }).values;
		for (const [name, value] of Object.entries(values)) this.keyCodes.set(name, value);

		this.host.style.position ||= "relative";
		this.host.append(this.canvas, this.textarea, this.mirror);
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
		if (!this.terminal || this.disposed) return;
		this.terminal.write(data);
		this.requestFrame();
	}

	focus(): void {
		this.textarea.focus({ preventScroll: true });
	}
	blur(): void {
		this.textarea.blur();
	}

	/** Viewport text, one line per row. */
	text(): string {
		return viewportText(this.snapshot ?? this.terminal.snapshot());
	}

	/** The selection's text, scrollback included. */
	selectedText(): string {
		return this.terminal?.selectedText() ?? "";
	}

	dispose(): void {
		this.disposed = true;
		this.observer?.disconnect();
		this.stopBlink();
		this.stopAutoscroll();
		if (this.mirrorTimer) clearTimeout(this.mirrorTimer);
		for (const cleanup of this.cleanups) cleanup();
		this.terminal?.dispose();
		this.canvas.remove();
		this.textarea.remove();
		this.mirror.remove();
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
			const changed = snapshot !== this.snapshot;
			this.snapshot = snapshot;
			paintSnapshot(this.ctx, snapshot, this.cell, {
				focused: this.focused,
				blinkOn: this.blinkOn,
				cursorColor: hex(this.options.theme.cursor),
				selectionColor: this.options.theme.selectionBackground,
				hoveredLink: this.hoveredLink,
				preedit: this.preedit,
			});
			const t2 = performance.now();
			this.frames.push({ snapshotMs: t1 - t0, paintMs: t2 - t1 });
			if (this.frames.length > 5000) this.frames.splice(0, this.frames.length - 5000);
			if (snapshot.cursor) {
				this.textarea.style.transform = `translate(${snapshot.cursor.column * this.cell.width}px, ${snapshot.cursor.row * this.cell.height}px)`;
			}
			this.syncBlink(snapshot);
			if (changed) this.scheduleMirror();
		});
	}

	/** The mirror trails the screen by a beat, so a stream of output is one update, not hundreds. */
	private scheduleMirror(): void {
		if (this.mirrorTimer) return;
		this.mirrorTimer = setTimeout(() => {
			this.mirrorTimer = null;
			if (this.disposed || !this.snapshot) return;
			const text = viewportText(this.snapshot);
			if (this.mirror.textContent !== text) this.mirror.textContent = text;
		}, MIRROR_DELAY_MS);
	}

	/** Blinks only a focused cursor the program asked to blink, and never under reduced motion. */
	private syncBlink(snapshot: TerminalSnapshot): void {
		const reduced = typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
		const wants = this.focused && !this.preedit && snapshot.cursor?.blinking === true && !reduced;
		if (wants && !this.blinkTimer) {
			this.blinkTimer = setInterval(() => {
				this.blinkOn = !this.blinkOn;
				this.requestFrame();
			}, BLINK_MS);
		} else if (!wants) {
			this.stopBlink();
		}
	}

	private stopBlink(): void {
		if (this.blinkTimer) clearInterval(this.blinkTimer);
		this.blinkTimer = null;
		this.blinkOn = true;
	}

	/** Typing restarts the blink in its visible phase, the way Ghostty does. */
	private restartBlink(): void {
		if (!this.blinkTimer) return;
		this.stopBlink();
		this.requestFrame();
	}

	private send(bytes: Uint8Array): void {
		if (bytes.length === 0) return;
		this.terminal.clearSelection();
		const s = this.snapshot;
		if (s && s.scrollback.offset + s.scrollback.length < s.scrollback.total) this.terminal.scrollToBottom();
		this.restartBlink();
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
			this.reportFocus(true);
			this.requestFrame();
		});
		this.listen(ta, "blur", () => {
			this.focused = false;
			this.altSide = null;
			this.reportFocus(false);
			this.requestFrame();
		});
		this.listen(ta, "keydown", (event) => this.onKeyDown(event));
		this.listen(ta, "keyup", (event) => {
			if (event.code === "AltLeft" || event.code === "AltRight") this.altSide = null;
			if (this.hoveredLink && !this.linkModifier(event)) {
				this.hoveredLink = null;
				this.canvas.style.cursor = this.terminal.mouseTracking() ? "default" : "text";
				this.requestFrame();
			}
		});
		this.listen(ta, "compositionstart", () => {
			this.composing = true;
		});
		this.listen(ta, "compositionupdate", (event) => {
			this.preedit = event.data ? this.terminal.module.graphemeWidths(event.data) : null;
			this.requestFrame();
		});
		let committed: string | null = null;
		this.listen(ta, "compositionend", (event) => {
			this.composing = false;
			this.preedit = null;
			committed = event.data || null;
			if (committed) this.send(encoder.encode(committed));
			else this.requestFrame();
			ta.value = "";
		});
		this.listen(ta, "input", (event) => {
			const input = event as InputEvent;
			if (this.composing || input.isComposing) return;
			// WebKit can follow compositionend with an input carrying the same commit.
			const echo = committed !== null && input.data === committed;
			committed = null;
			if (!echo && input.inputType === "insertText" && input.data) this.send(encoder.encode(input.data));
			ta.value = "";
		});
		this.listen(ta, "paste", (event) => {
			event.preventDefault();
			const text = event.clipboardData?.getData("text/plain");
			if (text) this.send(this.terminal.encodePaste(text));
		});
		this.listen(ta, "copy", (event) => {
			const text = this.terminal.selectedText();
			if (!text) return;
			event.preventDefault();
			event.clipboardData?.setData("text/plain", text);
		});
		this.listen(this.canvas, "mousedown", (event) => this.onMouseDown(event));
		this.listen(window, "mousemove", (event) => this.onMouseMove(event));
		this.listen(window, "mouseup", (event) => this.onMouseUp(event));
		this.listen(this.canvas, "contextmenu", (event) => {
			if (this.reportsMouse(event)) event.preventDefault();
		});
		this.listen(this.canvas, "wheel", (event) => this.onWheel(event), { passive: false });
	}

	private reportFocus(focused: boolean): void {
		const bytes = this.terminal.encodeFocus(focused);
		if (bytes.length > 0) this.options.onData(bytes);
	}

	private onKeyDown(event: KeyboardEvent): void {
		if (event.code === "AltLeft") this.altSide = "left";
		if (event.code === "AltRight") this.altSide = "right";
		if (event.isComposing || event.keyCode === 229) return;
		if (event.metaKey && this.mac) {
			// Cmd shortcuts stay the browser's: copy, paste, select-all, tab switching.
			return;
		}
		// Ctrl+Shift+C copies, as in Linux terminals; the browser has no copy shortcut there to fall back on.
		if (event.ctrlKey && event.shiftKey && event.code === "KeyC" && !this.mac) {
			const text = this.terminal.selectedText();
			if (text) {
				event.preventDefault();
				void navigator.clipboard?.writeText(text).catch(() => undefined);
			}
			return;
		}
		if (event.ctrlKey && event.shiftKey && event.code === "KeyV") return;
		// Shift+Insert pastes and Ctrl+Insert copies on Linux and Windows.
		if (!this.mac && event.code === "Insert" && event.shiftKey !== event.ctrlKey && !event.altKey) return;
		const input = keyInput(event, {
			mac: this.mac,
			optionAsAlt: this.options.macOptionAsAlt ?? "false",
			altSide: this.altSide,
		});
		if (!input) return;
		const key = this.keyCodes.get(ghosttyKeyName(event.code)) ?? 0;
		const bytes = this.terminal.encodeKey({ key, ...input, repeat: event.repeat });
		if (bytes.length === 0) return;
		event.preventDefault();
		this.send(bytes);
	}

	/**
	 * Mouse geometry on a whole-pixel cell grid. Cells are fractional CSS
	 * pixels wide; the library maps pixels to cells by integer division, so
	 * pointer positions are scaled onto integer cells to land in the right column.
	 */
	private surface(): SurfaceGeometry {
		const cellWidth = Math.max(1, Math.round(this.cell.width));
		const cellHeight = Math.max(1, Math.round(this.cell.height));
		return {
			cellWidth,
			cellHeight,
			width: this.terminal.columns * cellWidth,
			height: this.terminal.rows * cellHeight,
		};
	}

	private pointerAt(event: MouseEvent): PointerAt {
		const rect = this.canvas.getBoundingClientRect();
		const x = event.clientX - rect.left;
		const y = event.clientY - rect.top;
		const surface = this.surface();
		return {
			column: Math.min(this.terminal.columns - 1, Math.max(0, Math.floor(x / this.cell.width))),
			row: Math.min(this.terminal.rows - 1, Math.max(0, Math.floor(y / this.cell.height))),
			x: x * (surface.cellWidth / this.cell.width),
			y: y * (surface.cellHeight / this.cell.height),
		};
	}

	/** Shift always reaches the selection, so text stays copyable inside mouse-driven programs. */
	private reportsMouse(event: MouseEvent): boolean {
		return !event.shiftKey && this.terminal.mouseTracking();
	}

	private linkModifier(event: KeyboardEvent | MouseEvent): boolean {
		return this.mac ? event.metaKey : event.ctrlKey;
	}

	private mods(event: MouseEvent): number {
		return (
			(event.shiftKey ? MODS.shift : 0) |
			(event.ctrlKey ? MODS.ctrl : 0) |
			(event.altKey ? MODS.alt : 0) |
			(event.metaKey ? MODS.super : 0)
		);
	}

	private report(action: "press" | "release" | "motion", button: MouseButton | null, event: MouseEvent): void {
		const at = this.pointerAt(event);
		const bytes = this.terminal.encodeMouse(
			{ action, button, mods: this.mods(event), x: at.x, y: at.y },
			this.surface(),
			this.reportedButtons.size > 0,
		);
		if (bytes.length > 0) this.options.onData(bytes);
	}

	private onMouseDown(event: MouseEvent): void {
		event.preventDefault();
		this.focus();
		const at = this.pointerAt(event);
		if (event.button === 0 && this.linkModifier(event)) {
			const uri = this.terminal.hyperlinkAt(at);
			if (uri) {
				(this.options.onOpenLink ?? defaultOpenLink)(uri);
				return;
			}
		}
		if (this.reportsMouse(event)) {
			const button = DOM_BUTTONS[event.button];
			if (!button) return;
			this.reportedButtons.add(button);
			this.report("press", button, event);
			return;
		}
		if (event.button !== 0) return;
		this.pointer = at;
		this.selecting = true;
		if (this.terminal.selectionGesture("press", at, this.surface(), event.timeStamp)) this.requestFrame();
	}

	private onMouseMove(event: MouseEvent): void {
		if (this.reportedButtons.size > 0) {
			const held = [...this.reportedButtons].at(-1)!;
			this.report("motion", held, event);
			return;
		}
		const inside = event.target === this.canvas;
		if (this.selecting) {
			this.pointer = this.pointerAt(event);
			if (this.terminal.selectionGesture("drag", this.pointer, this.surface())) this.requestFrame();
			this.syncAutoscroll();
			return;
		}
		if (!inside) return;
		if (this.terminal.mouseTracking() && !event.shiftKey) this.report("motion", null, event);
		this.updateHover(event);
	}

	private onMouseUp(event: MouseEvent): void {
		const button = DOM_BUTTONS[event.button];
		if (button && this.reportedButtons.delete(button)) {
			this.report("release", button, event);
			return;
		}
		if (!this.selecting) return;
		this.selecting = false;
		this.stopAutoscroll();
		this.terminal.selectionGesture("release", this.pointerAt(event), this.surface());
		this.requestFrame();
	}

	private updateHover(event: MouseEvent): void {
		const at = this.pointerAt(event);
		let link: (RowSelection & { row: number }) | null = null;
		if (this.snapshot && this.linkModifier(event)) {
			const run = hyperlinkRunAt(this.snapshot, at);
			if (run && this.terminal.hyperlinkAt(at)) link = { row: at.row, ...run };
		}
		const same =
			link?.row === this.hoveredLink?.row && link?.start === this.hoveredLink?.start && link?.end === this.hoveredLink?.end;
		this.canvas.style.cursor = link ? "pointer" : this.terminal.mouseTracking() ? "default" : "text";
		if (same) return;
		this.hoveredLink = link;
		this.requestFrame();
	}

	/** A drag held past the top or bottom edge scrolls one row per tick, extending the selection into scrollback. */
	private syncAutoscroll(): void {
		const direction = this.terminal.autoscrollDirection();
		if (direction === 0) {
			this.stopAutoscroll();
			return;
		}
		if (this.autoscrollTimer) return;
		this.autoscrollTimer = setInterval(() => {
			if (!this.pointer || this.terminal.autoscrollDirection() === 0) {
				this.stopAutoscroll();
				return;
			}
			this.terminal.autoscrollTick(this.pointer, this.surface());
			this.requestFrame();
		}, AUTOSCROLL_MS);
	}

	private stopAutoscroll(): void {
		if (this.autoscrollTimer) clearInterval(this.autoscrollTimer);
		this.autoscrollTimer = null;
	}

	private onWheel(event: WheelEvent): void {
		event.preventDefault();
		const pixels = event.deltaMode === 1 ? event.deltaY * this.cell.height : event.deltaY;
		this.wheelRemainder += pixels;
		const rows = Math.trunc(this.wheelRemainder / this.cell.height);
		if (rows === 0) return;
		this.wheelRemainder -= rows * this.cell.height;
		if (this.reportsMouse(event)) {
			const button: MouseButton = rows < 0 ? "wheel-up" : "wheel-down";
			for (let i = 0; i < Math.abs(rows); i++) this.report("press", button, event);
			return;
		}
		// The alternate screen has no scrollback; with mode 1007 the wheel becomes
		// arrow keys, so less, man and vim scroll the way they do in Ghostty.
		if (this.terminal.alternateScreen() && this.terminal.mode(1007)) {
			const key = this.keyCodes.get(rows < 0 ? "ARROW_UP" : "ARROW_DOWN") ?? 0;
			const arrow = this.terminal.encodeKey({ key, mods: 0 });
			for (let i = 0; i < Math.abs(rows); i++) this.options.onData(arrow);
			return;
		}
		this.terminal.scrollViewport(rows);
		this.requestFrame();
	}
}
