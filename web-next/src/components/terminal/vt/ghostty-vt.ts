/*
 * libghostty-vt 1.0 from Ghostty's signed release wasm (#1846 spike). Loads
 * the module same-origin, checks it against the pinned release SHA-256, and
 * wraps the stable C API in VtTerminal: bytes in, TerminalSnapshot out, plus
 * the key, paste and scroll calls a canvas front end needs. Enum values and
 * struct offsets come from the module's own ghostty_type_json(), not from
 * numbers copied out of headers.
 */
import {
	type CellStyle,
	PLAIN_STYLE,
	type Rgb,
	RunBuilder,
	type TerminalCursor,
	type TerminalSnapshot,
	type TextRun,
} from "./snapshot";

export type VtBuild = "fast" | "small";

/** Ghostty's release artifacts, verified with minisign against key RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV. */
export const GHOSTTY_VT_RELEASE = {
	version: "1.0.0",
	builds: {
		fast: {
			file: "ghostty-vt-1.0.0.wasm",
			sha256: "7b428fee6d0677bc81279458f8f9a3335454834123a9ff47efb3fd177f6da5a8",
		},
		small: {
			file: "ghostty-vt-1.0.0-small.wasm",
			sha256: "dad8e14ce8da57db3864f66ae36caf66a17c4e2691ad0a0110e05c746de047a4",
		},
	},
	origin: "https://release.files.ghostty.org/libghostty-vt/1.0.0/",
	servedFrom: "/dev/terminal-vt/",
} as const;

interface EnumLayout {
	kind: "enum";
	values: Record<string, number>;
}
interface StructLayout {
	kind: "struct";
	size: number;
	fields: Record<string, { offset: number; size: number }>;
}
interface TypeLayout {
	library_version: string;
	types: Record<string, EnumLayout | StructLayout | { kind: string }>;
}

type Exports = Record<string, (...args: (number | bigint)[]) => number> & {
	memory: WebAssembly.Memory;
	__indirect_function_table: WebAssembly.Table;
};

const SUCCESS = 0;
const OUT_OF_SPACE = -3;

export class VtError extends Error {
	constructor(
		readonly operation: string,
		readonly code: number,
	) {
		super(`libghostty-vt ${operation} failed (${code})`);
	}
}

const check = (operation: string, result: number) => {
	if (result !== SUCCESS) throw new VtError(operation, result);
};

/**
 * A wasm function that calls a JS function, so it can sit in the module's
 * function table as a C callback. The release module has no imports, and a
 * table only takes wasm functions; re-exporting an import makes one.
 * Signature: (i32, i32, i32, i32) -> ().
 */
function callbackTrampoline(fn: (a: number, b: number, c: number, d: number) => void) {
	const bytes = new Uint8Array([
		0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
		0x01, 0x08, 0x01, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x00,
		0x02, 0x07, 0x01, 0x01, 0x68, 0x01, 0x66, 0x00, 0x00,
		0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
	]);
	const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), { h: { f: fn } });
	return instance.exports.f as (...args: number[]) => void;
}

export class VtModule {
	readonly exports: Exports;
	readonly layout: TypeLayout;
	readonly version: string;

	constructor(instance: WebAssembly.Instance) {
		this.exports = instance.exports as unknown as Exports;
		const jsonPtr = this.exports.ghostty_type_json();
		const bytes = this.u8();
		let end = jsonPtr;
		while (bytes[end] !== 0) end++;
		this.layout = JSON.parse(new TextDecoder().decode(bytes.subarray(jsonPtr, end)));
		this.version = this.layout.library_version;
	}

	/** Reacquired on every access: any export that allocates may grow memory. */
	u8(): Uint8Array {
		return new Uint8Array(this.exports.memory.buffer);
	}
	view(): DataView {
		return new DataView(this.exports.memory.buffer);
	}

	enumValue(type: string, key: string): number {
		const layout = this.layout.types[type] as EnumLayout | undefined;
		const value = layout?.values?.[key];
		if (value === undefined) throw new Error(`no ${type}.${key} in libghostty-vt ${this.version}`);
		return value;
	}

	struct(type: string): StructLayout {
		const layout = this.layout.types[type] as StructLayout | undefined;
		if (layout?.kind !== "struct") throw new Error(`no struct ${type}`);
		return layout;
	}

	offset(type: string, field: string): number {
		return this.struct(type).fields[field].offset;
	}

	alloc(length: number): number {
		const ptr = this.exports.ghostty_wasm_alloc(length);
		if (ptr === 0) throw new VtError("wasm_alloc", -1);
		return ptr;
	}

	free(ptr: number, length: number): void {
		this.exports.ghostty_wasm_free(ptr, length);
	}

	/** Runs a constructor that fills an opaque out-slot and returns the handle. */
	construct(operation: string, call: (slot: number) => number): number {
		const slot = this.exports.ghostty_wasm_alloc_opaque();
		try {
			check(operation, call(slot));
			return this.exports.ghostty_wasm_take_opaque(slot);
		} finally {
			this.exports.ghostty_wasm_free_opaque(slot);
		}
	}

	/** Installs a JS function in the module's table; returns its C function pointer. */
	installCallback(fn: (a: number, b: number, c: number, d: number) => void): number {
		const table = this.exports.__indirect_function_table;
		const index = table.grow(1);
		table.set(index, callbackTrampoline(fn));
		return index;
	}
}

export async function verifySha256(bytes: ArrayBuffer, expected: string): Promise<void> {
	const digest = await crypto.subtle.digest("SHA-256", bytes);
	const hex = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
	if (hex !== expected) {
		throw new Error(`ghostty-vt wasm checksum mismatch: expected ${expected}, got ${hex}`);
	}
}

export async function instantiateVt(bytes: ArrayBuffer): Promise<VtModule> {
	const { instance } = await WebAssembly.instantiate(bytes, {});
	return new VtModule(instance);
}

const cache = new Map<VtBuild, Promise<VtModule>>();

/** Fetches, verifies and instantiates one release build, once per page. */
export function loadGhosttyVt(build: VtBuild = "fast"): Promise<VtModule> {
	let pending = cache.get(build);
	if (!pending) {
		const { file, sha256 } = GHOSTTY_VT_RELEASE.builds[build];
		pending = (async () => {
			const response = await fetch(`${GHOSTTY_VT_RELEASE.servedFrom}${file}`);
			if (!response.ok) {
				throw new Error(
					`ghostty-vt wasm not served (HTTP ${response.status}); run \`pnpm spike:ghostty-vt\``,
				);
			}
			const bytes = await response.arrayBuffer();
			await verifySha256(bytes, sha256);
			return instantiateVt(bytes);
		})();
		pending.catch(() => cache.delete(build));
		cache.set(build, pending);
	}
	return pending;
}

export interface VtTerminalOptions {
	columns: number;
	rows: number;
	scrollbackLines?: number;
	fg?: Rgb;
	bg?: Rgb;
	/** Overrides for palette entries 0–15. */
	palette?: Partial<Record<number, Rgb>>;
	/** Replies the terminal owes the program (device attributes, cursor reports). */
	onReply?: (bytes: Uint8Array) => void;
}

/** Flag bits of GhosttyStyleFlags, frozen by the 1.0 ABI. */
const BOLD = 1 << 0;
const ITALIC = 1 << 1;
const FAINT = 1 << 2;
const INVERSE = 1 << 4;
const INVISIBLE = 1 << 5;
const STRIKETHROUGH = 1 << 6;
const UNDERLINE_MASK = 0b111 << 8;

/**
 * One terminal and the render-state handles that read it. Not thread-safe,
 * like the handles it owns; call dispose() to free them.
 */
export class VtTerminal {
	columns: number;
	rows: number;

	private readonly m: VtModule;
	private readonly e: Exports;
	private readonly terminal: number;
	private readonly renderState: number;
	private readonly rowIterator: number;
	private readonly rowCells: number;
	private readonly keyEncoder: number;
	private readonly keyEvent: number;
	/** Scratch for out-parameters; its address survives memory growth. */
	private readonly scratch: number;
	private readonly scratchSize = 256;
	private graphemeBuffer: number;
	private graphemeCapacity = 32;
	private lastSnapshot: TerminalSnapshot | null = null;
	private readonly decoder = new TextDecoder();
	private readonly encoder = new TextEncoder();
	private readonly k: Record<string, number>;
	private onReply: ((bytes: Uint8Array) => void) | null = null;
	/**
	 * Replies arrive inside ghostty_terminal_vt_write. They go out after it
	 * returns, so a transport that echoes synchronously cannot re-enter the parser.
	 */
	private pendingReplies: Uint8Array[] = [];

	constructor(module: VtModule, options: VtTerminalOptions) {
		this.m = module;
		this.e = module.exports;
		this.columns = options.columns;
		this.rows = options.rows;
		const ev = (type: string, key: string) => module.enumValue(type, key);
		this.k = {
			rsDirty: ev("GhosttyRenderStateData", "DIRTY"),
			rsRowIterator: ev("GhosttyRenderStateData", "ROW_ITERATOR"),
			rsFg: ev("GhosttyRenderStateData", "COLOR_FOREGROUND"),
			rsBg: ev("GhosttyRenderStateData", "COLOR_BACKGROUND"),
			rsCursor: ev("GhosttyRenderStateData", "CURSOR"),
			rowCells: ev("GhosttyRenderStateRowData", "CELLS"),
			cellRaw: ev("GhosttyRenderStateRowCellsData", "RAW"),
			cellStyle: ev("GhosttyRenderStateRowCellsData", "STYLE"),
			cellFg: ev("GhosttyRenderStateRowCellsData", "FG_COLOR"),
			cellBg: ev("GhosttyRenderStateRowCellsData", "BG_COLOR"),
			cellHasStyling: ev("GhosttyRenderStateRowCellsData", "HAS_STYLING"),
			cellGraphemes: ev("GhosttyRenderStateRowCellsData", "GRAPHEMES_UTF8"),
			cellDataWide: ev("GhosttyCellData", "WIDE"),
			wide: ev("GhosttyCellWide", "WIDE"),
			spacerTail: ev("GhosttyCellWide", "SPACER_TAIL"),
			spacerHead: ev("GhosttyCellWide", "SPACER_HEAD"),
			dirtyFalse: ev("GhosttyRenderStateDirty", "FALSE"),
			termScrollbar: ev("GhosttyTerminalData", "SCROLLBAR"),
			termMode: ev("GhosttyTerminalData", "MODE"),
			termPaletteDefault: ev("GhosttyTerminalData", "COLOR_PALETTE_DEFAULT"),
			optWritePty: ev("GhosttyTerminalOption", "WRITE_PTY"),
			optScrollbackLines: ev("GhosttyTerminalOption", "SCROLLBACK_MAX_LINES"),
			optFg: ev("GhosttyTerminalOption", "COLOR_FOREGROUND"),
			optBg: ev("GhosttyTerminalOption", "COLOR_BACKGROUND"),
			optPalette: ev("GhosttyTerminalOption", "COLOR_PALETTE"),
			scrollDelta: ev("GhosttyTerminalScrollViewportTag", "DELTA"),
			scrollBottom: ev("GhosttyTerminalScrollViewportTag", "BOTTOM"),
			keyPress: ev("GhosttyKeyAction", "PRESS"),
			keyRepeat: ev("GhosttyKeyAction", "REPEAT"),
		};

		this.scratch = module.alloc(this.scratchSize);
		this.graphemeBuffer = module.alloc(this.graphemeCapacity);
		this.terminal = module.construct("terminal_new", (slot) =>
			this.e.ghostty_terminal_new(0, slot, options.columns, options.rows),
		);
		this.renderState = module.construct("render_state_new", (slot) =>
			this.e.ghostty_render_state_new(0, slot),
		);
		this.rowIterator = module.construct("row_iterator_new", (slot) =>
			this.e.ghostty_render_state_row_iterator_new(0, slot),
		);
		this.rowCells = module.construct("row_cells_new", (slot) =>
			this.e.ghostty_render_state_row_cells_new(0, slot),
		);
		this.keyEncoder = module.construct("key_encoder_new", (slot) =>
			this.e.ghostty_key_encoder_new(0, slot),
		);
		this.keyEvent = module.construct("key_event_new", (slot) =>
			this.e.ghostty_key_event_new(0, slot),
		);

		this.view().setUint32(this.scratch, options.scrollbackLines ?? 10_000, true);
		check("set(scrollback)", this.e.ghostty_terminal_set(this.terminal, this.k.optScrollbackLines, this.scratch));
		this.setColors(options);

		if (options.onReply) {
			this.onReply = options.onReply;
			const callback = module.installCallback((_terminal, _userdata, ptr, length) => {
				this.pendingReplies.push(this.m.u8().slice(ptr, ptr + length));
			});
			check("set(write_pty)", this.e.ghostty_terminal_set(this.terminal, this.k.optWritePty, callback));
		}
	}

	private view(): DataView {
		return this.m.view();
	}

	setColors(options: Pick<VtTerminalOptions, "fg" | "bg" | "palette">): void {
		const writeRgb = (ptr: number, rgb: Rgb) => {
			const bytes = this.m.u8();
			bytes[ptr] = (rgb >> 16) & 0xff;
			bytes[ptr + 1] = (rgb >> 8) & 0xff;
			bytes[ptr + 2] = rgb & 0xff;
		};
		if (options.fg !== undefined) {
			writeRgb(this.scratch, options.fg);
			check("set(fg)", this.e.ghostty_terminal_set(this.terminal, this.k.optFg, this.scratch));
		}
		if (options.bg !== undefined) {
			writeRgb(this.scratch, options.bg);
			check("set(bg)", this.e.ghostty_terminal_set(this.terminal, this.k.optBg, this.scratch));
		}
		if (options.palette) {
			const palette = this.m.alloc(256 * 3);
			try {
				check("get(palette_default)", this.e.ghostty_terminal_get(this.terminal, this.k.termPaletteDefault, palette));
				for (const [index, rgb] of Object.entries(options.palette)) {
					if (rgb !== undefined) writeRgb(palette + Number(index) * 3, rgb);
				}
				check("set(palette)", this.e.ghostty_terminal_set(this.terminal, this.k.optPalette, palette));
			} finally {
				this.m.free(palette, 256 * 3);
			}
		}
		this.lastSnapshot = null;
	}

	/** Never fails: partial sequences wait for the next write. */
	write(data: Uint8Array | string): void {
		const bytes = typeof data === "string" ? this.encoder.encode(data) : data;
		if (bytes.length === 0) return;
		const ptr = this.m.alloc(bytes.length);
		this.m.u8().set(bytes, ptr);
		this.e.ghostty_terminal_vt_write(this.terminal, ptr, bytes.length);
		this.m.free(ptr, bytes.length);
		if (this.pendingReplies.length === 0 || !this.onReply) return;
		const replies = this.pendingReplies;
		this.pendingReplies = [];
		for (const reply of replies) this.onReply(reply);
	}

	resize(columns: number, rows: number, cellWidthPx = 0, cellHeightPx = 0): void {
		if (columns === this.columns && rows === this.rows) return;
		check(
			"terminal_resize",
			this.e.ghostty_terminal_resize(this.terminal, columns, rows, Math.round(cellWidthPx), Math.round(cellHeightPx)),
		);
		this.columns = columns;
		this.rows = rows;
	}

	/** Moves the viewport by whole rows; negative scrolls into history. */
	scrollViewport(deltaRows: number): void {
		const layout = this.m.struct("GhosttyTerminalScrollViewport");
		const view = this.view();
		const p = this.scratch;
		view.setInt32(p + layout.fields.tag.offset, this.k.scrollDelta, true);
		view.setInt32(p + layout.fields.value.offset, deltaRows, true);
		check("scroll_viewport", this.e.ghostty_terminal_scroll_viewport(this.terminal, p));
	}

	scrollToBottom(): void {
		const layout = this.m.struct("GhosttyTerminalScrollViewport");
		this.view().setInt32(this.scratch + layout.fields.tag.offset, this.k.scrollBottom, true);
		check("scroll_viewport", this.e.ghostty_terminal_scroll_viewport(this.terminal, this.scratch));
	}

	/** Whether a mode is set: DEC private unless `ansi`. */
	mode(value: number, ansi = false): boolean {
		const view = this.view();
		view.setUint16(this.scratch, (value & 0x7fff) | (ansi ? 0x8000 : 0), true);
		view.setUint8(this.scratch + 2, 0);
		check("get(mode)", this.e.ghostty_terminal_get(this.terminal, this.k.termMode, this.scratch));
		return this.view().getUint8(this.scratch + 2) !== 0;
	}

	/**
	 * Encodes a key press the way the program asked for it (cursor-key mode,
	 * kitty flags, modifyOtherKeys), synced from the terminal on every call.
	 */
	encodeKey(event: {
		key: number;
		mods: number;
		text?: string;
		unshiftedCodepoint?: number;
		repeat?: boolean;
	}): Uint8Array {
		const e = this.e;
		check("encoder_from_terminal", e.ghostty_key_encoder_set_from_terminal(this.keyEncoder, this.terminal));
		e.ghostty_key_event_set_action(this.keyEvent, event.repeat ? this.k.keyRepeat : this.k.keyPress);
		e.ghostty_key_event_set_key(this.keyEvent, event.key);
		e.ghostty_key_event_set_mods(this.keyEvent, event.mods);
		e.ghostty_key_event_set_unshifted_codepoint(this.keyEvent, event.unshiftedCodepoint ?? 0);
		const text = event.text ? this.encoder.encode(event.text) : null;
		const stringLayout = this.m.struct("GhosttyString");
		const stringPtr = this.scratch + 64;
		let textPtr = 0;
		if (text && text.length > 0) {
			textPtr = this.m.alloc(text.length);
			this.m.u8().set(text, textPtr);
			const view = this.view();
			view.setUint32(stringPtr + stringLayout.fields.ptr.offset, textPtr, true);
			view.setUint32(stringPtr + stringLayout.fields.len.offset, text.length, true);
		} else {
			const view = this.view();
			view.setUint32(stringPtr + stringLayout.fields.ptr.offset, 0, true);
			view.setUint32(stringPtr + stringLayout.fields.len.offset, 0, true);
		}
		try {
			e.ghostty_key_event_set_utf8(this.keyEvent, stringPtr);
			const out = this.scratch + 128;
			const cap = 64;
			const written = this.scratch + 4;
			const result = e.ghostty_key_encoder_encode(this.keyEncoder, this.keyEvent, out, cap, written);
			if (result !== SUCCESS) return new Uint8Array();
			const length = this.view().getUint32(written, true);
			return this.m.u8().slice(out, out + length);
		} finally {
			if (textPtr) this.m.free(textPtr, text!.length);
		}
	}

	/**
	 * Pasted text as the program should receive it: bracketed when mode 2004
	 * is on, with the control bytes that could run commands replaced
	 * (Ghostty's fix for CVE-2026-26982).
	 */
	encodePaste(text: string): Uint8Array {
		const data = this.encoder.encode(text);
		const bracketed = this.mode(2004);
		const capacity = data.length + 16;
		const dataPtr = this.m.alloc(Math.max(1, data.length));
		const out = this.m.alloc(capacity);
		try {
			this.m.u8().set(data, dataPtr);
			check(
				"paste_encode",
				this.e.ghostty_paste_encode(dataPtr, data.length, bracketed ? 1 : 0, out, capacity, this.scratch),
			);
			const length = this.view().getUint32(this.scratch, true);
			return this.m.u8().slice(out, out + length);
		} finally {
			this.m.free(dataPtr, Math.max(1, data.length));
			this.m.free(out, capacity);
		}
	}

	/**
	 * The current viewport. A clean frame returns the cached snapshot without
	 * walking a cell; a partly dirty one rebuilds only the dirty rows. The
	 * dirty flag tracks rows only, so cursor and colors compare separately.
	 */
	snapshot(): TerminalSnapshot {
		const e = this.e;
		check("render_state_update", e.ghostty_render_state_update(this.renderState, this.terminal));
		const p = this.scratch;
		e.ghostty_render_state_get(this.renderState, this.k.rsDirty, p);
		const dirty = this.view().getInt32(p, true);
		const fg = this.renderColor(this.k.rsFg);
		const bg = this.renderColor(this.k.rsBg);
		const cursor = this.cursor();
		const scrollback = this.scrollbar();
		const last = this.lastSnapshot;
		const geometryHolds = last && last.columns === this.columns && last.rows === this.rows;
		if (
			dirty === this.k.dirtyFalse &&
			last &&
			geometryHolds &&
			last.fg === fg &&
			last.bg === bg &&
			sameCursor(last.cursor, cursor) &&
			last.scrollback.offset === scrollback.offset &&
			last.scrollback.total === scrollback.total
		) {
			return last;
		}

		this.view().setUint32(p, this.rowIterator, true);
		check("get(row_iterator)", e.ghostty_render_state_get(this.renderState, this.k.rsRowIterator, p));
		const lines: TextRun[][] = [];
		const rowDirtyKey = this.m.enumValue("GhosttyRenderStateRowData", "DIRTY");
		const reuse = geometryHolds && last && last.fg === fg && last.bg === bg;
		const builder = new RunBuilder();
		while (e.ghostty_render_state_row_iterator_next(this.rowIterator)) {
			const index = lines.length;
			if (reuse) {
				e.ghostty_render_state_row_get(this.rowIterator, rowDirtyKey, p);
				if (this.view().getUint8(p) === 0 && last.lines[index]) {
					lines.push(last.lines[index]);
					continue;
				}
			}
			this.view().setUint32(p, this.rowCells, true);
			check("row_get(cells)", e.ghostty_render_state_row_get(this.rowIterator, this.k.rowCells, p));
			while (e.ghostty_render_state_row_cells_next(this.rowCells)) {
				const wide = this.cellWide();
				if (wide === this.k.spacerTail || wide === this.k.spacerHead) {
					builder.skip();
					continue;
				}
				builder.append(this.grapheme(), wide === this.k.wide ? 2 : 1, this.cellStyle());
			}
			lines.push(builder.finish());
		}
		e.ghostty_render_state_clean(this.renderState);
		const snapshot: TerminalSnapshot = {
			columns: this.columns,
			rows: this.rows,
			fg,
			bg,
			cursor,
			lines,
			scrollback,
		};
		this.lastSnapshot = snapshot;
		return snapshot;
	}

	private cellWide(): number {
		const p = this.scratch;
		this.e.ghostty_render_state_row_cells_get(this.rowCells, this.k.cellRaw, p);
		const raw = this.view().getBigUint64(p, true);
		this.e.ghostty_cell_get(raw, this.k.cellDataWide, p);
		return this.view().getInt32(p, true);
	}

	/** An unwritten cell reads as a single space. */
	private grapheme(): string {
		const layout = this.m.struct("GhosttyBuffer");
		const p = this.scratch + 32;
		for (;;) {
			const view = this.view();
			view.setUint32(p + layout.fields.ptr.offset, this.graphemeBuffer, true);
			view.setUint32(p + layout.fields.cap.offset, this.graphemeCapacity, true);
			view.setUint32(p + layout.fields.len.offset, 0, true);
			const result = this.e.ghostty_render_state_row_cells_get(this.rowCells, this.k.cellGraphemes, p);
			const length = this.view().getUint32(p + layout.fields.len.offset, true);
			if (result === OUT_OF_SPACE) {
				this.m.free(this.graphemeBuffer, this.graphemeCapacity);
				this.graphemeCapacity = Math.max(length, this.graphemeCapacity * 2);
				this.graphemeBuffer = this.m.alloc(this.graphemeCapacity);
				continue;
			}
			if (result !== SUCCESS || length === 0) return " ";
			return this.decoder.decode(this.m.u8().subarray(this.graphemeBuffer, this.graphemeBuffer + length));
		}
	}

	private cellStyle(): CellStyle {
		const p = this.scratch;
		const e = this.e;
		const fg = this.cellColor(this.k.cellFg);
		const bg = this.cellColor(this.k.cellBg);
		e.ghostty_render_state_row_cells_get(this.rowCells, this.k.cellHasStyling, p);
		if (this.view().getUint8(p) === 0) {
			return fg === null && bg === null ? PLAIN_STYLE : { ...PLAIN_STYLE, fg, bg };
		}
		e.ghostty_render_state_row_cells_get(this.rowCells, this.k.cellStyle, p);
		const flags = this.view().getUint16(p + this.m.offset("GhosttyStyle", "flags"), true);
		return {
			fg,
			bg,
			bold: (flags & BOLD) !== 0,
			italic: (flags & ITALIC) !== 0,
			faint: (flags & FAINT) !== 0,
			inverse: (flags & INVERSE) !== 0,
			invisible: (flags & INVISIBLE) !== 0,
			strikethrough: (flags & STRIKETHROUGH) !== 0,
			underline: (flags & UNDERLINE_MASK) !== 0,
		};
	}

	/** Resolved through the palette by the library; null means "the default". */
	private cellColor(key: number): Rgb | null {
		const p = this.scratch + 16;
		if (this.e.ghostty_render_state_row_cells_get(this.rowCells, key, p) !== SUCCESS) return null;
		return readRgb(this.m.u8(), p);
	}

	private renderColor(key: number): Rgb {
		const p = this.scratch + 16;
		this.e.ghostty_render_state_get(this.renderState, key, p);
		return readRgb(this.m.u8(), p);
	}

	private cursor(): TerminalCursor | null {
		const layout = this.m.struct("GhosttyRenderStateCursor");
		const p = this.scratch + 32;
		const view = this.view();
		for (let i = 0; i < layout.size; i++) view.setUint8(p + i, 0);
		view.setUint32(p + layout.fields.size.offset, layout.size, true);
		if (this.e.ghostty_render_state_get(this.renderState, this.k.rsCursor, p) !== SUCCESS) return null;
		const v = this.view();
		const f = layout.fields;
		if (!v.getUint8(p + f.visible.offset) || !v.getUint8(p + f.viewport_has_value.offset)) return null;
		return {
			column: v.getUint16(p + f.viewport_x.offset, true),
			row: v.getUint16(p + f.viewport_y.offset, true),
			wide: v.getUint8(p + f.wide_tail.offset) !== 0,
		};
	}

	private scrollbar(): TerminalSnapshot["scrollback"] {
		const layout = this.m.struct("GhosttyTerminalScrollbar");
		const p = this.scratch + 32;
		if (this.e.ghostty_terminal_get(this.terminal, this.k.termScrollbar, p) !== SUCCESS) {
			return { total: 0, offset: 0, length: this.rows };
		}
		const v = this.view();
		return {
			total: Number(v.getBigUint64(p + layout.fields.total.offset, true)),
			offset: Number(v.getBigUint64(p + layout.fields.offset.offset, true)),
			length: Number(v.getBigUint64(p + layout.fields.len.offset, true)),
		};
	}

	dispose(): void {
		const e = this.e;
		e.ghostty_key_event_free(this.keyEvent);
		e.ghostty_key_encoder_free(this.keyEncoder);
		e.ghostty_render_state_row_cells_free(this.rowCells);
		e.ghostty_render_state_row_iterator_free(this.rowIterator);
		e.ghostty_render_state_free(this.renderState);
		e.ghostty_terminal_free(this.terminal);
		this.m.free(this.graphemeBuffer, this.graphemeCapacity);
		this.m.free(this.scratch, this.scratchSize);
	}
}

function readRgb(bytes: Uint8Array, ptr: number): Rgb {
	return (bytes[ptr] << 16) | (bytes[ptr + 1] << 8) | bytes[ptr + 2];
}

function sameCursor(a: TerminalCursor | null, b: TerminalCursor | null): boolean {
	if (a === null || b === null) return a === b;
	return a.column === b.column && a.row === b.row && a.wide === b.wide;
}
