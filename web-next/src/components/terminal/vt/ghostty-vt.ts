/*
 * libghostty-vt 1.0 from Ghostty's signed release wasm. Loads the module
 * same-origin, checks it against the pinned release SHA-256, and wraps the
 * stable C API in VtTerminal: bytes in, TerminalSnapshot out, plus the key,
 * paste, mouse, focus, selection, hyperlink and scroll calls a canvas front
 * end needs. Enum values and struct layouts come from the module's own
 * ghostty_type_json(), not from numbers copied out of headers.
 */
import {
	type CellStyle,
	type CursorShape,
	PLAIN_STYLE,
	type Rgb,
	type RowSelection,
	RunBuilder,
	type TerminalCursor,
	type TerminalSnapshot,
	type TextRun,
} from "./snapshot";

/**
 * The one pin. Ghostty's release artifact, verified with minisign against the
 * key below before its digest was recorded. `pnpm build` runs
 * scripts/fetch-ghostty-vt.mjs, which downloads and re-checks it into
 * public/<servedFrom>, so every deploy serves it same-origin; loadGhosttyVt
 * checks it again in the page.
 */
export const GHOSTTY_VT_RELEASE = {
	version: "1.0.0",
	file: "ghostty-vt-1.0.0-small.wasm",
	sha256: "dad8e14ce8da57db3864f66ae36caf66a17c4e2691ad0a0110e05c746de047a4",
	minisignKey: "RWQlAjJC23149WL2sEpT/l0QKy7hMIFhYdQOFy0Z7z7PbneUgvlsnYcV",
	origin: "https://release.files.ghostty.org/libghostty-vt/1.0.0/",
	servedFrom: "/ghostty-vt/",
} as const;

interface EnumLayout {
	kind: "enum";
	values: Record<string, number>;
}
interface FieldLayout {
	offset: number;
	size: number;
	type?: string;
}
interface StructLayout {
	kind: "struct";
	size: number;
	fields: Record<string, FieldLayout>;
}
interface TypeLayout {
	library_version: string;
	abi?: { usize_size: number };
	types: Record<string, EnumLayout | StructLayout | { kind: string }>;
}

type Exports = Record<string, (...args: (number | bigint)[]) => number> & {
	memory: WebAssembly.Memory;
	__indirect_function_table: WebAssembly.Table;
};

const SUCCESS = 0;
const NO_VALUE = -4;
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

	/** The value's key in an enum, for mapping library values back to names. */
	enumKey(type: string, value: number): string | undefined {
		const layout = this.layout.types[type] as EnumLayout | undefined;
		return Object.entries(layout?.values ?? {}).find(([, v]) => v === value)?.[0];
	}

	struct(type: string): StructLayout {
		const layout = this.layout.types[type] as StructLayout | undefined;
		if (layout?.kind !== "struct") throw new Error(`no struct ${type}`);
		return layout;
	}

	offset(type: string, field: string): number {
		return this.field(type, field).offset;
	}

	private field(type: string, field: string): FieldLayout {
		const layout = this.struct(type).fields[field];
		if (!layout) throw new Error(`no field ${type}.${field} in libghostty-vt ${this.version}`);
		return layout;
	}

	/** Zeroes a struct at `ptr` and, for a sized struct, fills in its size field. */
	initStruct(ptr: number, type: string): void {
		const layout = this.struct(type);
		this.u8().fill(0, ptr, ptr + layout.size);
		if (layout.fields.size) this.write(ptr, type, "size", layout.size);
	}

	/** Writes one field, picking the width and encoding from the manifest. */
	write(ptr: number, type: string, field: string, value: number | boolean | bigint): void {
		const { offset, size, type: kind } = this.field(type, field);
		const view = this.view();
		const at = ptr + offset;
		if (kind === "f64") view.setFloat64(at, Number(value), true);
		else if (kind === "f32") view.setFloat32(at, Number(value), true);
		else if (size === 8) view.setBigUint64(at, BigInt(value), true);
		else if (size === 4) view.setUint32(at, Number(value) >>> 0, true);
		else if (size === 2) view.setUint16(at, Number(value), true);
		else view.setUint8(at, Number(value));
	}

	read(ptr: number, type: string, field: string): number {
		const { offset, size, type: kind } = this.field(type, field);
		const view = this.view();
		const at = ptr + offset;
		if (kind === "f64") return view.getFloat64(at, true);
		if (kind === "f32") return view.getFloat32(at, true);
		if (size === 8) return Number(view.getBigUint64(at, true));
		if (size === 4) return view.getUint32(at, true);
		if (size === 2) return view.getUint16(at, true);
		return view.getUint8(at);
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

	private freeCallbackSlots: number[] = [];

	/** Installs a JS function in the module's table; returns its C function pointer. */
	installCallback(fn: (a: number, b: number, c: number, d: number) => void): number {
		const table = this.exports.__indirect_function_table;
		const index = this.freeCallbackSlots.pop() ?? table.grow(1);
		table.set(index, callbackTrampoline(fn));
		return index;
	}

	/** Empties a slot from installCallback so the next terminal reuses it. */
	releaseCallback(index: number): void {
		this.exports.__indirect_function_table.set(index, null);
		this.freeCallbackSlots.push(index);
	}

	/**
	 * Splits text into grapheme clusters with the terminal's own widths, so an
	 * IME preedit occupies the cells the committed text will.
	 */
	graphemeWidths(text: string): { text: string; width: number }[] {
		const codepoints = Array.from(text, (c) => c.codePointAt(0)!);
		if (codepoints.length === 0) return [];
		const bytes = codepoints.length * 4;
		const ptr = this.alloc(bytes + 4);
		try {
			const view = this.view();
			codepoints.forEach((cp, i) => view.setUint32(ptr + i * 4, cp, true));
			const out: { text: string; width: number }[] = [];
			let at = 0;
			while (at < codepoints.length) {
				const used = this.exports.ghostty_unicode_grapheme_width(ptr + at * 4, codepoints.length - at, ptr + bytes);
				const step = Math.max(1, used);
				out.push({
					text: String.fromCodePoint(...codepoints.slice(at, at + step)),
					width: this.view().getUint8(ptr + bytes),
				});
				at += step;
			}
			return out;
		} finally {
			this.free(ptr, bytes + 4);
		}
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

let cached: Promise<VtModule> | null = null;

/** Fetches, verifies and instantiates the pinned release, once per page. */
export function loadGhosttyVt(): Promise<VtModule> {
	if (!cached) {
		const { file, sha256, servedFrom } = GHOSTTY_VT_RELEASE;
		const pending = (async () => {
			const response = await fetch(`${servedFrom}${file}`);
			if (!response.ok) {
				throw new Error(`ghostty-vt wasm not served (HTTP ${response.status}); run \`pnpm ghostty-vt:fetch\``);
			}
			const bytes = await response.arrayBuffer();
			await verifySha256(bytes, sha256);
			return instantiateVt(bytes);
		})();
		pending.catch(() => {
			cached = null;
		});
		cached = pending;
	}
	return cached;
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

/** A pointer position on the canvas, with the viewport cell under it. */
export interface PointerAt {
	row: number;
	column: number;
	/** Surface pixels from the canvas's top-left corner. */
	x: number;
	y: number;
}

/** The canvas geometry the mouse encoder and selection gestures map pixels with. */
export interface SurfaceGeometry {
	width: number;
	height: number;
	cellWidth: number;
	cellHeight: number;
}

export type MouseAction = "press" | "release" | "motion";
/** DOM MouseEvent.button order, plus the wheel as buttons 4–7 the way xterm reports it. */
export type MouseButton = "left" | "middle" | "right" | "wheel-up" | "wheel-down" | "wheel-left" | "wheel-right";

const MOUSE_BUTTONS: Record<MouseButton, string> = {
	left: "LEFT",
	right: "RIGHT",
	middle: "MIDDLE",
	"wheel-up": "FOUR",
	"wheel-down": "FIVE",
	"wheel-left": "SIX",
	"wheel-right": "SEVEN",
};

const CURSOR_SHAPES: Record<string, CursorShape> = {
	BAR: "bar",
	BLOCK: "block",
	UNDERLINE: "underline",
	BLOCK_HOLLOW: "block_hollow",
};

/** Flag bits of GhosttyStyleFlags, frozen by the 1.0 ABI. */
const BOLD = 1 << 0;
const ITALIC = 1 << 1;
const FAINT = 1 << 2;
const INVERSE = 1 << 4;
const INVISIBLE = 1 << 5;
const STRIKETHROUGH = 1 << 6;
const OVERLINE = 1 << 7;
const UNDERLINE_MASK = 0b111 << 8;

/** Clicks closer together than this, and nearer than a cell, count toward double and triple click. */
const REPEAT_CLICK_MS = 500;

/**
 * Fixed regions of one scratch allocation for out-parameters and struct
 * arguments. Its address survives memory growth; the constructor checks each
 * struct fits its region, so an ABI change fails loudly rather than overlapping.
 */
const SCRATCH = {
	out: 0, // 16: scalar out-values
	written: 16, // 8: size_t written counts
	color: 24, // 8: GhosttyColorRgb
	struct: 32, // 128: cursor, scrollbar, buffer, row selection, sized option structs
	string: 160, // 16: GhosttyString
	point: 176, // 32: GhosttyPoint
	refA: 208, // 16: GhosttyGridRef
	selection: 224, // 64: GhosttySelection
	position: 288, // 32: GhosttySurfacePosition / GhosttyMousePosition
	value: 320, // 32: option values (u64 times, doubles, bools)
	io: 384, // 640: encoder output
	size: 1024,
} as const;
const IO_CAPACITY = SCRATCH.size - SCRATCH.io;

/**
 * One terminal and the handles that read and drive it. Not thread-safe, like
 * the handles it owns; call dispose() to free them.
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
	private readonly mouseEncoder: number;
	private readonly mouseEvent: number;
	private readonly gesture: number;
	private readonly gestureEvents: Record<"press" | "drag" | "release" | "tick", number>;
	private readonly scratch: number;
	private graphemeBuffer: number;
	private graphemeCapacity = 32;
	private lastSnapshot: TerminalSnapshot | null = null;
	/**
	 * Set by every write, which may change mouse modes. Syncing the mouse
	 * encoder from the terminal also forgets the last reported cell, so it
	 * syncs only after a write, or motion within one cell would repeat.
	 */
	private mouseModesStale = true;
	/** The geometry last given to the mouse encoder; setting it also forgets the last cell, so it is set only on change. */
	private mouseSize = "";
	/** Bumped whenever this wrapper changes the selection; the clean-frame cache compares it. */
	private selectionGeneration = 0;
	private snapshotSelectionGeneration = -1;
	private readonly decoder = new TextDecoder();
	private readonly encoder = new TextEncoder();
	private readonly k: Record<string, number>;
	private onReply: ((bytes: Uint8Array) => void) | null = null;
	/**
	 * Replies arrive inside ghostty_terminal_vt_write. They go out after it
	 * returns, so a transport that echoes synchronously cannot re-enter the parser.
	 */
	private pendingReplies: Uint8Array[] = [];
	private replyCallback: number | null = null;
	private disposed = false;

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
			rowDirty: ev("GhosttyRenderStateRowData", "DIRTY"),
			rowRaw: ev("GhosttyRenderStateRowData", "RAW"),
			rowCells: ev("GhosttyRenderStateRowData", "CELLS"),
			rowSelection: ev("GhosttyRenderStateRowData", "SELECTION"),
			rowHasHyperlink: ev("GhosttyRowData", "HYPERLINK"),
			cellRaw: ev("GhosttyRenderStateRowCellsData", "RAW"),
			cellStyle: ev("GhosttyRenderStateRowCellsData", "STYLE"),
			cellFg: ev("GhosttyRenderStateRowCellsData", "FG_COLOR"),
			cellBg: ev("GhosttyRenderStateRowCellsData", "BG_COLOR"),
			cellHasStyling: ev("GhosttyRenderStateRowCellsData", "HAS_STYLING"),
			cellGraphemes: ev("GhosttyRenderStateRowCellsData", "GRAPHEMES_UTF8"),
			cellDataWide: ev("GhosttyCellData", "WIDE"),
			cellDataHyperlink: ev("GhosttyCellData", "HAS_HYPERLINK"),
			wide: ev("GhosttyCellWide", "WIDE"),
			spacerTail: ev("GhosttyCellWide", "SPACER_TAIL"),
			spacerHead: ev("GhosttyCellWide", "SPACER_HEAD"),
			dirtyFalse: ev("GhosttyRenderStateDirty", "FALSE"),
			dirtyFull: ev("GhosttyRenderStateDirty", "FULL"),
			termScrollbar: ev("GhosttyTerminalData", "SCROLLBAR"),
			termMode: ev("GhosttyTerminalData", "MODE"),
			termMouseTracking: ev("GhosttyTerminalData", "MOUSE_TRACKING"),
			termSelection: ev("GhosttyTerminalData", "SELECTION"),
			termPaletteDefault: ev("GhosttyTerminalData", "COLOR_PALETTE_DEFAULT"),
			optWritePty: ev("GhosttyTerminalOption", "WRITE_PTY"),
			optScrollbackLines: ev("GhosttyTerminalOption", "SCROLLBACK_MAX_LINES"),
			optScrollbackBytes: ev("GhosttyTerminalOption", "SCROLLBACK_MAX_BYTES"),
			termActiveScreen: ev("GhosttyTerminalData", "ACTIVE_SCREEN"),
			screenAlternate: ev("GhosttyTerminalScreen", "ALTERNATE"),
			optFg: ev("GhosttyTerminalOption", "COLOR_FOREGROUND"),
			optBg: ev("GhosttyTerminalOption", "COLOR_BACKGROUND"),
			optPalette: ev("GhosttyTerminalOption", "COLOR_PALETTE"),
			optSelection: ev("GhosttyTerminalOption", "SELECTION"),
			scrollDelta: ev("GhosttyTerminalScrollViewportTag", "DELTA"),
			scrollBottom: ev("GhosttyTerminalScrollViewportTag", "BOTTOM"),
			pointViewport: ev("GhosttyPointTag", "VIEWPORT"),
			keyPress: ev("GhosttyKeyAction", "PRESS"),
			keyRepeat: ev("GhosttyKeyAction", "REPEAT"),
			mouseOptSize: ev("GhosttyMouseEncoderOption", "SIZE"),
			mouseOptAnyPressed: ev("GhosttyMouseEncoderOption", "ANY_BUTTON_PRESSED"),
			mouseOptTrackLastCell: ev("GhosttyMouseEncoderOption", "TRACK_LAST_CELL"),
			focusGained: ev("GhosttyFocusEvent", "GAINED"),
			focusLost: ev("GhosttyFocusEvent", "LOST"),
			gestureOptRef: ev("GhosttySelectionGestureEventOption", "REF"),
			gestureOptPosition: ev("GhosttySelectionGestureEventOption", "POSITION"),
			gestureOptRepeatDistance: ev("GhosttySelectionGestureEventOption", "REPEAT_DISTANCE"),
			gestureOptTime: ev("GhosttySelectionGestureEventOption", "TIME_NS"),
			gestureOptRepeatInterval: ev("GhosttySelectionGestureEventOption", "REPEAT_INTERVAL_NS"),
			gestureOptGeometry: ev("GhosttySelectionGestureEventOption", "GEOMETRY"),
			gestureOptViewport: ev("GhosttySelectionGestureEventOption", "VIEWPORT"),
			gestureDataAutoscroll: ev("GhosttySelectionGestureData", "AUTOSCROLL"),
			autoscrollUp: ev("GhosttySelectionGestureAutoscroll", "UP"),
			autoscrollDown: ev("GhosttySelectionGestureAutoscroll", "DOWN"),
			formatterEmit: ev("GhosttyFormatterOption", "EMIT"),
			formatterUnwrap: ev("GhosttyFormatterOption", "UNWRAP"),
			formatterTrim: ev("GhosttyFormatterOption", "TRIM"),
			formatterSelection: ev("GhosttyFormatterOption", "SELECTION"),
			formatPlain: ev("GhosttyFormatterFormat", "PLAIN"),
		};
		const fits: [string, number][] = [
			["GhosttyRenderStateCursor", 128],
			["GhosttyTerminalScrollbar", 128],
			["GhosttyRenderStateRowSelection", 128],
			["GhosttyMouseEncoderSize", 128],
			["GhosttySelectionGestureGeometry", 128],
			["GhosttyString", 16],
			["GhosttyBuffer", 128],
			["GhosttyStyle", 128],
			["GhosttyTerminalScrollViewport", 128],
			["GhosttyPoint", 32],
			["GhosttyGridRef", 16],
			["GhosttySelection", 64],
			["GhosttySurfacePosition", 32],
			["GhosttyMousePosition", 32],
			["GhosttyPointCoordinate", 32],
		];
		for (const [type, room] of fits) {
			if (module.struct(type).size > room) throw new Error(`${type} outgrew its scratch region`);
		}

		this.scratch = module.alloc(SCRATCH.size);
		this.graphemeBuffer = module.alloc(this.graphemeCapacity);
		const e = this.e;
		this.terminal = module.construct("terminal_new", (slot) => e.ghostty_terminal_new(0, slot, options.columns, options.rows));
		this.renderState = module.construct("render_state_new", (slot) => e.ghostty_render_state_new(0, slot));
		this.rowIterator = module.construct("row_iterator_new", (slot) => e.ghostty_render_state_row_iterator_new(0, slot));
		this.rowCells = module.construct("row_cells_new", (slot) => e.ghostty_render_state_row_cells_new(0, slot));
		this.keyEncoder = module.construct("key_encoder_new", (slot) => e.ghostty_key_encoder_new(0, slot));
		this.keyEvent = module.construct("key_event_new", (slot) => e.ghostty_key_event_new(0, slot));
		this.mouseEncoder = module.construct("mouse_encoder_new", (slot) => e.ghostty_mouse_encoder_new(0, slot));
		this.mouseEvent = module.construct("mouse_event_new", (slot) => e.ghostty_mouse_event_new(0, slot));
		this.gesture = module.construct("selection_gesture_new", (slot) => e.ghostty_selection_gesture_new(0, slot));
		const gestureEvent = (type: string) =>
			module.construct("selection_gesture_event_new", (slot) =>
				e.ghostty_selection_gesture_event_new(0, slot, ev("GhosttySelectionGestureEventType", type)),
			);
		this.gestureEvents = {
			press: gestureEvent("PRESS"),
			drag: gestureEvent("DRAG"),
			release: gestureEvent("RELEASE"),
			tick: gestureEvent("AUTOSCROLL_TICK"),
		};
		const value = this.scratch + SCRATCH.value;
		this.view().setBigUint64(value, BigInt(REPEAT_CLICK_MS) * 1_000_000n, true);
		check("gesture(repeat_interval)", e.ghostty_selection_gesture_event_set(this.gestureEvents.press, this.k.gestureOptRepeatInterval, value));
		this.view().setUint8(value, 1);
		check("mouse(track_last_cell)", e.ghostty_mouse_encoder_set(this.mouseEncoder, this.k.mouseOptTrackLastCell, value));

		// The library's default byte cap (10,000 bytes, one page in practice) would end
		// history after a few hundred rows; lifting it leaves the line limit in charge.
		const out = this.scratch + SCRATCH.out;
		this.view().setUint32(out, options.scrollbackLines ?? 10_000, true);
		check("set(scrollback_lines)", e.ghostty_terminal_set(this.terminal, this.k.optScrollbackLines, out));
		if ((module.layout.abi?.usize_size ?? 4) === 8) this.view().setBigUint64(out, 0xffff_ffff_ffff_ffffn, true);
		else this.view().setUint32(out, 0xffff_ffff, true);
		check("set(scrollback_bytes)", e.ghostty_terminal_set(this.terminal, this.k.optScrollbackBytes, out));
		this.setColors(options);

		if (options.onReply) {
			this.onReply = options.onReply;
			this.replyCallback = module.installCallback((_terminal, _userdata, ptr, length) => {
				this.pendingReplies.push(this.m.u8().slice(ptr, ptr + length));
			});
			check("set(write_pty)", e.ghostty_terminal_set(this.terminal, this.k.optWritePty, this.replyCallback));
		}
	}

	get module(): VtModule {
		return this.m;
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
		const color = this.scratch + SCRATCH.color;
		if (options.fg !== undefined) {
			writeRgb(color, options.fg);
			check("set(fg)", this.e.ghostty_terminal_set(this.terminal, this.k.optFg, color));
		}
		if (options.bg !== undefined) {
			writeRgb(color, options.bg);
			check("set(bg)", this.e.ghostty_terminal_set(this.terminal, this.k.optBg, color));
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
		if (this.disposed) return;
		const bytes = typeof data === "string" ? this.encoder.encode(data) : data;
		if (bytes.length === 0) return;
		const ptr = this.m.alloc(bytes.length);
		this.m.u8().set(bytes, ptr);
		this.e.ghostty_terminal_vt_write(this.terminal, ptr, bytes.length);
		this.m.free(ptr, bytes.length);
		this.mouseModesStale = true;
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
		const p = this.scratch + SCRATCH.struct;
		this.m.write(p, "GhosttyTerminalScrollViewport", "tag", this.k.scrollDelta);
		this.view().setInt32(p + this.m.offset("GhosttyTerminalScrollViewport", "value"), deltaRows, true);
		check("scroll_viewport", this.e.ghostty_terminal_scroll_viewport(this.terminal, p));
	}

	scrollToBottom(): void {
		const p = this.scratch + SCRATCH.struct;
		this.m.write(p, "GhosttyTerminalScrollViewport", "tag", this.k.scrollBottom);
		check("scroll_viewport", this.e.ghostty_terminal_scroll_viewport(this.terminal, p));
	}

	/** Whether a mode is set: DEC private unless `ansi`. */
	mode(value: number, ansi = false): boolean {
		const p = this.scratch + SCRATCH.out;
		const view = this.view();
		view.setUint16(p, (value & 0x7fff) | (ansi ? 0x8000 : 0), true);
		view.setUint8(p + 2, 0);
		check("get(mode)", this.e.ghostty_terminal_get(this.terminal, this.k.termMode, p));
		return this.view().getUint8(p + 2) !== 0;
	}

	/** Whether the alternate screen (full-screen programs: less, vim, top) is active. */
	alternateScreen(): boolean {
		const p = this.scratch + SCRATCH.out;
		this.view().setUint32(p, 0, true);
		check("get(active_screen)", this.e.ghostty_terminal_get(this.terminal, this.k.termActiveScreen, p));
		return this.view().getUint32(p, true) === this.k.screenAlternate;
	}

	/** Whether the program asked for mouse reports (any of modes 9, 1000, 1002, 1003). */
	mouseTracking(): boolean {
		const p = this.scratch + SCRATCH.out;
		this.view().setUint8(p, 0);
		check("get(mouse_tracking)", this.e.ghostty_terminal_get(this.terminal, this.k.termMouseTracking, p));
		return this.view().getUint8(p) !== 0;
	}

	/**
	 * Encodes a key press the way the program asked for it (cursor-key mode,
	 * kitty flags, modifyOtherKeys), synced from the terminal on every call.
	 * The macOS Option policy is the caller's: the wasm build compiles out the
	 * encoder's macos_option_as_alt option, so Alt in `mods` always means Alt.
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
		const stringPtr = this.scratch + SCRATCH.string;
		let textPtr = 0;
		if (text && text.length > 0) {
			textPtr = this.m.alloc(text.length);
			this.m.u8().set(text, textPtr);
		}
		this.m.write(stringPtr, "GhosttyString", "ptr", textPtr);
		this.m.write(stringPtr, "GhosttyString", "len", text?.length ?? 0);
		try {
			e.ghostty_key_event_set_utf8(this.keyEvent, stringPtr);
			const out = this.scratch + SCRATCH.io;
			const written = this.scratch + SCRATCH.written;
			if (e.ghostty_key_encoder_encode(this.keyEncoder, this.keyEvent, out, IO_CAPACITY, written) !== SUCCESS) {
				return new Uint8Array();
			}
			return this.m.u8().slice(out, out + this.view().getUint32(written, true));
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
		const written = this.scratch + SCRATCH.written;
		try {
			this.m.u8().set(data, dataPtr);
			check("paste_encode", this.e.ghostty_paste_encode(dataPtr, data.length, bracketed ? 1 : 0, out, capacity, written));
			return this.m.u8().slice(out, out + this.view().getUint32(written, true));
		} finally {
			this.m.free(dataPtr, Math.max(1, data.length));
			this.m.free(out, capacity);
		}
	}

	/**
	 * A mouse report in the program's tracking mode and format (X10, normal,
	 * button, any-event; SGR, UTF-8, urxvt, SGR-pixels), or nothing when the
	 * program did not ask for this event. Motion within one cell is reported once
	 * (until the next write, which re-reads the program's modes).
	 */
	encodeMouse(
		event: { action: MouseAction; button: MouseButton | null; mods: number; x: number; y: number },
		surface: SurfaceGeometry,
		anyButtonPressed: boolean,
	): Uint8Array {
		const e = this.e;
		const m = this.m;
		if (this.mouseModesStale) {
			check("mouse_encoder_from_terminal", e.ghostty_mouse_encoder_set_from_terminal(this.mouseEncoder, this.terminal));
			this.mouseModesStale = false;
		}
		const geometry = [surface.width, surface.height, surface.cellWidth, surface.cellHeight].map(Math.round);
		if (geometry.join() !== this.mouseSize) {
			const [width, height, cellWidth, cellHeight] = geometry;
			const size = this.scratch + SCRATCH.struct;
			m.initStruct(size, "GhosttyMouseEncoderSize");
			m.write(size, "GhosttyMouseEncoderSize", "screen_width", width);
			m.write(size, "GhosttyMouseEncoderSize", "screen_height", height);
			m.write(size, "GhosttyMouseEncoderSize", "cell_width", Math.max(1, cellWidth));
			m.write(size, "GhosttyMouseEncoderSize", "cell_height", Math.max(1, cellHeight));
			check("mouse(size)", e.ghostty_mouse_encoder_set(this.mouseEncoder, this.k.mouseOptSize, size));
			this.mouseSize = geometry.join();
		}
		const value = this.scratch + SCRATCH.value;
		this.view().setUint8(value, anyButtonPressed ? 1 : 0);
		check("mouse(any_pressed)", e.ghostty_mouse_encoder_set(this.mouseEncoder, this.k.mouseOptAnyPressed, value));

		const action = m.enumValue("GhosttyMouseAction", event.action.toUpperCase());
		check("mouse_event(action)", e.ghostty_mouse_event_set_action(this.mouseEvent, action));
		if (event.button) {
			const button = m.enumValue("GhosttyMouseButton", MOUSE_BUTTONS[event.button]);
			check("mouse_event(button)", e.ghostty_mouse_event_set_button(this.mouseEvent, button));
		} else {
			check("mouse_event(clear_button)", e.ghostty_mouse_event_clear_button(this.mouseEvent));
		}
		check("mouse_event(mods)", e.ghostty_mouse_event_set_mods(this.mouseEvent, event.mods));
		// By-value struct arguments travel by pointer in the wasm32 C ABI.
		const position = this.scratch + SCRATCH.position;
		m.write(position, "GhosttyMousePosition", "x", event.x);
		m.write(position, "GhosttyMousePosition", "y", event.y);
		check("mouse_event(position)", e.ghostty_mouse_event_set_position(this.mouseEvent, position));

		const out = this.scratch + SCRATCH.io;
		const written = this.scratch + SCRATCH.written;
		if (e.ghostty_mouse_encoder_encode(this.mouseEncoder, this.mouseEvent, out, IO_CAPACITY, written) !== SUCCESS) {
			return new Uint8Array();
		}
		return m.u8().slice(out, out + this.view().getUint32(written, true));
	}

	/** The focus report the program asked for with mode 1004, or nothing. */
	encodeFocus(focused: boolean): Uint8Array {
		if (!this.mode(1004)) return new Uint8Array();
		const out = this.scratch + SCRATCH.io;
		const written = this.scratch + SCRATCH.written;
		check(
			"focus_encode",
			this.e.ghostty_focus_encode(focused ? this.k.focusGained : this.k.focusLost, out, IO_CAPACITY, written),
		);
		return this.m.u8().slice(out, out + this.view().getUint32(written, true));
	}

	/** Writes the grid ref of a viewport cell into `out`; false when the cell is off-screen. */
	private gridRef(at: { row: number; column: number }, out: number): boolean {
		const m = this.m;
		const point = this.scratch + SCRATCH.point;
		m.initStruct(point, "GhosttyPoint");
		m.write(point, "GhosttyPoint", "tag", this.k.pointViewport);
		const coordinate = point + m.offset("GhosttyPoint", "value");
		m.write(coordinate, "GhosttyPointCoordinate", "x", Math.max(0, Math.min(this.columns - 1, at.column)));
		m.write(coordinate, "GhosttyPointCoordinate", "y", Math.max(0, Math.min(this.rows - 1, at.row)));
		return this.e.ghostty_terminal_grid_ref(this.terminal, point, out) === SUCCESS;
	}

	/** The OSC 8 URI of a viewport cell, or null. */
	hyperlinkAt(at: { row: number; column: number }): string | null {
		const ref = this.scratch + SCRATCH.refA;
		if (!this.gridRef(at, ref)) return null;
		const written = this.scratch + SCRATCH.written;
		const result = this.e.ghostty_grid_ref_hyperlink_uri(ref, 0, 0, written);
		const length = this.view().getUint32(written, true);
		if (result !== OUT_OF_SPACE || length === 0) return null;
		const buf = this.m.alloc(length);
		try {
			check("grid_ref_hyperlink_uri", this.e.ghostty_grid_ref_hyperlink_uri(ref, buf, length, written));
			return this.decoder.decode(this.m.u8().subarray(buf, buf + this.view().getUint32(written, true)));
		} finally {
			this.m.free(buf, length);
		}
	}

	/**
	 * Feeds one pointer event to Ghostty's selection gesture: press counts
	 * clicks (one: cell, two: word, three: line), drag extends from the press
	 * anchor, release ends the gesture. A resulting selection is installed on
	 * the terminal, which tracks it through scrollback and new output. Returns
	 * whether the visible selection changed.
	 */
	selectionGesture(
		kind: "press" | "drag" | "release",
		at: PointerAt,
		surface: SurfaceGeometry,
		timeMs = 0,
	): boolean {
		const e = this.e;
		const m = this.m;
		const event = this.gestureEvents[kind];
		const ref = this.scratch + SCRATCH.refA;
		const onGrid = this.gridRef(at, ref);
		if (kind !== "release" && !onGrid) return false;
		if (onGrid) check("gesture(ref)", e.ghostty_selection_gesture_event_set(event, this.k.gestureOptRef, ref));
		else check("gesture(ref)", e.ghostty_selection_gesture_event_set(event, this.k.gestureOptRef, 0));
		if (kind !== "release") {
			const position = this.scratch + SCRATCH.position;
			m.write(position, "GhosttySurfacePosition", "x", at.x);
			m.write(position, "GhosttySurfacePosition", "y", at.y);
			check("gesture(position)", e.ghostty_selection_gesture_event_set(event, this.k.gestureOptPosition, position));
		}
		if (kind === "press") {
			const value = this.scratch + SCRATCH.value;
			this.view().setBigUint64(value, BigInt(Math.round(timeMs * 1_000_000)), true);
			check("gesture(time)", e.ghostty_selection_gesture_event_set(event, this.k.gestureOptTime, value));
			this.view().setFloat64(value, surface.cellWidth, true);
			check("gesture(repeat_distance)", e.ghostty_selection_gesture_event_set(event, this.k.gestureOptRepeatDistance, value));
		}
		if (kind === "drag") this.setGestureGeometry(event, surface);
		const selection = this.scratch + SCRATCH.selection;
		const result = e.ghostty_selection_gesture_event(this.gesture, this.terminal, event, kind === "release" ? 0 : selection);
		if (result === SUCCESS) return this.installSelection(selection);
		// A single press anchors the gesture without selecting; the old selection goes, the anchor stays.
		if (result === NO_VALUE) return kind === "press" ? this.clearSelection(false) : false;
		throw new VtError(`selection_gesture(${kind})`, result);
	}

	/** Which way a drag past the top or bottom edge wants the viewport to move: -1 up, 1 down, 0 neither. */
	autoscrollDirection(): -1 | 0 | 1 {
		const p = this.scratch + SCRATCH.out;
		this.view().setUint32(p, 0, true);
		if (this.e.ghostty_selection_gesture_get(this.gesture, this.terminal, this.k.gestureDataAutoscroll, p) !== SUCCESS) {
			return 0;
		}
		const value = this.view().getUint32(p, true);
		return value === this.k.autoscrollUp ? -1 : value === this.k.autoscrollDown ? 1 : 0;
	}

	/** Scrolls one row toward the drag and extends the selection there; returns whether it moved. */
	autoscrollTick(at: PointerAt, surface: SurfaceGeometry): boolean {
		const m = this.m;
		const event = this.gestureEvents.tick;
		const coordinate = this.scratch + SCRATCH.point;
		m.initStruct(coordinate, "GhosttyPointCoordinate");
		m.write(coordinate, "GhosttyPointCoordinate", "x", Math.max(0, Math.min(this.columns - 1, at.column)));
		m.write(coordinate, "GhosttyPointCoordinate", "y", Math.max(0, Math.min(this.rows - 1, at.row)));
		check("gesture(viewport)", this.e.ghostty_selection_gesture_event_set(event, this.k.gestureOptViewport, coordinate));
		const position = this.scratch + SCRATCH.position;
		m.write(position, "GhosttySurfacePosition", "x", at.x);
		m.write(position, "GhosttySurfacePosition", "y", at.y);
		check("gesture(position)", this.e.ghostty_selection_gesture_event_set(event, this.k.gestureOptPosition, position));
		this.setGestureGeometry(event, surface);
		const selection = this.scratch + SCRATCH.selection;
		const result = this.e.ghostty_selection_gesture_event(this.gesture, this.terminal, event, selection);
		if (result !== SUCCESS) return false;
		return this.installSelection(selection);
	}

	private setGestureGeometry(event: number, surface: SurfaceGeometry): void {
		const m = this.m;
		const geometry = this.scratch + SCRATCH.struct;
		m.initStruct(geometry, "GhosttySelectionGestureGeometry");
		m.write(geometry, "GhosttySelectionGestureGeometry", "columns", this.columns);
		m.write(geometry, "GhosttySelectionGestureGeometry", "cell_width", Math.max(1, Math.round(surface.cellWidth)));
		m.write(geometry, "GhosttySelectionGestureGeometry", "screen_height", Math.round(surface.height));
		check("gesture(geometry)", this.e.ghostty_selection_gesture_event_set(event, this.k.gestureOptGeometry, geometry));
	}

	private installSelection(selection: number): boolean {
		check("set(selection)", this.e.ghostty_terminal_set(this.terminal, this.k.optSelection, selection));
		this.selectionGeneration++;
		return true;
	}

	/** Drops the selection, and by default the gesture in progress; returns whether there was one. */
	clearSelection(resetGesture = true): boolean {
		if (resetGesture) this.e.ghostty_selection_gesture_reset(this.gesture, this.terminal);
		if (!this.hasSelection()) return false;
		check("set(selection)", this.e.ghostty_terminal_set(this.terminal, this.k.optSelection, 0));
		this.selectionGeneration++;
		return true;
	}

	hasSelection(): boolean {
		return this.e.ghostty_terminal_get(this.terminal, this.k.termSelection, this.scratch + SCRATCH.selection) === SUCCESS;
	}

	/**
	 * The selected text, scrollback included, with soft-wrapped lines joined
	 * and trailing blanks trimmed, through Ghostty's formatter. Empty when
	 * nothing is selected.
	 */
	selectedText(): string {
		const e = this.e;
		const selection = this.scratch + SCRATCH.selection;
		if (e.ghostty_terminal_get(this.terminal, this.k.termSelection, selection) !== SUCCESS) return "";
		const formatter = this.m.construct("formatter_terminal_new", (slot) => e.ghostty_formatter_terminal_new(0, slot, this.terminal));
		try {
			const value = this.scratch + SCRATCH.value;
			this.view().setUint32(value, this.k.formatPlain, true);
			check("formatter(emit)", e.ghostty_formatter_set(formatter, this.k.formatterEmit, value));
			this.view().setUint8(value, 1);
			check("formatter(unwrap)", e.ghostty_formatter_set(formatter, this.k.formatterUnwrap, value));
			check("formatter(trim)", e.ghostty_formatter_set(formatter, this.k.formatterTrim, value));
			check("formatter(selection)", e.ghostty_formatter_set(formatter, this.k.formatterSelection, selection));
			const written = this.scratch + SCRATCH.written;
			let capacity = 4096;
			for (;;) {
				// ghostty_wasm_free needs the size this block was allocated with, so it is pinned per attempt.
				const size = capacity;
				const buf = this.m.alloc(size);
				try {
					const result = e.ghostty_formatter_format_buf(formatter, buf, size, written);
					const length = this.view().getUint32(written, true);
					if (result === OUT_OF_SPACE) {
						capacity = Math.max(length, size * 2);
						continue;
					}
					check("formatter_format", result);
					return this.decoder.decode(this.m.u8().subarray(buf, buf + length));
				} finally {
					this.m.free(buf, size);
				}
			}
		} finally {
			e.ghostty_formatter_free(formatter);
		}
	}

	/**
	 * The current viewport. A clean frame returns the cached snapshot without
	 * walking a cell; a partly dirty one rebuilds only the dirty rows. The
	 * dirty flag tracks rows only, so cursor, colors and selection compare separately.
	 */
	snapshot(): TerminalSnapshot {
		const e = this.e;
		check("render_state_update", e.ghostty_render_state_update(this.renderState, this.terminal));
		const p = this.scratch + SCRATCH.out;
		e.ghostty_render_state_get(this.renderState, this.k.rsDirty, p);
		const dirty = this.view().getInt32(p, true);
		const fg = this.renderColor(this.k.rsFg);
		const bg = this.renderColor(this.k.rsBg);
		const cursor = this.cursor();
		const scrollback = this.scrollbar();
		const last = this.lastSnapshot;
		const geometryHolds = last !== null && last.columns === this.columns && last.rows === this.rows;
		if (
			dirty === this.k.dirtyFalse &&
			last &&
			geometryHolds &&
			last.fg === fg &&
			last.bg === bg &&
			sameCursor(last.cursor, cursor) &&
			this.snapshotSelectionGeneration === this.selectionGeneration &&
			last.scrollback.offset === scrollback.offset &&
			last.scrollback.total === scrollback.total
		) {
			return last;
		}

		this.view().setUint32(p, this.rowIterator, true);
		check("get(row_iterator)", e.ghostty_render_state_get(this.renderState, this.k.rsRowIterator, p));
		const lines: TextRun[][] = [];
		const selection: (RowSelection | null)[] = [];
		// A FULL frame redraws every row whatever its own flag says (palette change, screen switch).
		const reuse = dirty !== this.k.dirtyFull && geometryHolds && last && last.fg === fg && last.bg === bg;
		const builder = new RunBuilder();
		while (e.ghostty_render_state_row_iterator_next(this.rowIterator)) {
			const index = lines.length;
			selection.push(this.rowSelection());
			if (reuse) {
				e.ghostty_render_state_row_get(this.rowIterator, this.k.rowDirty, p);
				if (this.view().getUint8(p) === 0 && last.lines[index]) {
					lines.push(last.lines[index]);
					continue;
				}
			}
			const links = this.rowHasHyperlinks();
			this.view().setUint32(p, this.rowCells, true);
			check("row_get(cells)", e.ghostty_render_state_row_get(this.rowIterator, this.k.rowCells, p));
			while (e.ghostty_render_state_row_cells_next(this.rowCells)) {
				const raw = this.cellRaw();
				const wide = this.cellData(raw, this.k.cellDataWide);
				// A spacer head is a blank in the style it was written with, and Ghostty paints its background.
				if (wide === this.k.spacerTail) {
					builder.skip();
					continue;
				}
				const hyperlink = links && this.cellData(raw, this.k.cellDataHyperlink) !== 0;
				builder.append(this.grapheme(), wide === this.k.wide ? 2 : 1, this.cellStyle(hyperlink));
			}
			lines.push(builder.finish());
		}
		e.ghostty_render_state_clean(this.renderState);
		const snapshot: TerminalSnapshot = { columns: this.columns, rows: this.rows, fg, bg, cursor, lines, selection, scrollback };
		this.lastSnapshot = snapshot;
		this.snapshotSelectionGeneration = this.selectionGeneration;
		return snapshot;
	}

	private rowSelection(): RowSelection | null {
		const p = this.scratch + SCRATCH.struct;
		const type = "GhosttyRenderStateRowSelection";
		this.m.initStruct(p, type);
		if (this.e.ghostty_render_state_row_get(this.rowIterator, this.k.rowSelection, p) !== SUCCESS) return null;
		return { start: this.m.read(p, type, "start_x"), end: this.m.read(p, type, "end_x") };
	}

	/** The row flag may report links that are gone; it never misses one, so it gates the per-cell check. */
	private rowHasHyperlinks(): boolean {
		const p = this.scratch + SCRATCH.out;
		if (this.e.ghostty_render_state_row_get(this.rowIterator, this.k.rowRaw, p) !== SUCCESS) return true;
		const raw = this.view().getBigUint64(p, true);
		this.view().setUint8(p + 8, 0);
		if (this.e.ghostty_row_get(raw, this.k.rowHasHyperlink, p + 8) !== SUCCESS) return true;
		return this.view().getUint8(p + 8) !== 0;
	}

	private cellRaw(): bigint {
		const p = this.scratch + SCRATCH.out;
		this.e.ghostty_render_state_row_cells_get(this.rowCells, this.k.cellRaw, p);
		return this.view().getBigUint64(p, true);
	}

	/** One property of a raw cell; GhosttyCell is a u64, so it crosses as a BigInt. */
	private cellData(raw: bigint, key: number): number {
		const p = this.scratch + SCRATCH.out + 8;
		this.view().setUint32(p, 0, true);
		this.e.ghostty_cell_get(raw, key, p);
		return this.view().getUint32(p, true);
	}

	/** An unwritten cell reads as a single space. */
	private grapheme(): string {
		const m = this.m;
		const p = this.scratch + SCRATCH.struct;
		for (;;) {
			m.write(p, "GhosttyBuffer", "ptr", this.graphemeBuffer);
			m.write(p, "GhosttyBuffer", "cap", this.graphemeCapacity);
			m.write(p, "GhosttyBuffer", "len", 0);
			const result = this.e.ghostty_render_state_row_cells_get(this.rowCells, this.k.cellGraphemes, p);
			const length = m.read(p, "GhosttyBuffer", "len");
			if (result === OUT_OF_SPACE) {
				m.free(this.graphemeBuffer, this.graphemeCapacity);
				this.graphemeCapacity = Math.max(length, this.graphemeCapacity * 2);
				this.graphemeBuffer = m.alloc(this.graphemeCapacity);
				continue;
			}
			if (result !== SUCCESS || length === 0) return " ";
			return this.decoder.decode(m.u8().subarray(this.graphemeBuffer, this.graphemeBuffer + length));
		}
	}

	private cellStyle(hyperlink: boolean): CellStyle {
		const p = this.scratch + SCRATCH.out;
		const e = this.e;
		const fg = this.cellColor(this.k.cellFg);
		const bg = this.cellColor(this.k.cellBg);
		e.ghostty_render_state_row_cells_get(this.rowCells, this.k.cellHasStyling, p);
		if (this.view().getUint8(p) === 0) {
			return fg === null && bg === null && !hyperlink ? PLAIN_STYLE : { ...PLAIN_STYLE, fg, bg, hyperlink };
		}
		const style = this.scratch + SCRATCH.struct;
		e.ghostty_render_state_row_cells_get(this.rowCells, this.k.cellStyle, style);
		const flags = this.view().getUint16(style + this.m.offset("GhosttyStyle", "flags"), true);
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
			overline: (flags & OVERLINE) !== 0,
			hyperlink,
		};
	}

	/** Resolved through the palette by the library; null means "the default". */
	private cellColor(key: number): Rgb | null {
		const p = this.scratch + SCRATCH.color;
		if (this.e.ghostty_render_state_row_cells_get(this.rowCells, key, p) !== SUCCESS) return null;
		return readRgb(this.m.u8(), p);
	}

	private renderColor(key: number): Rgb {
		const p = this.scratch + SCRATCH.color;
		this.e.ghostty_render_state_get(this.renderState, key, p);
		return readRgb(this.m.u8(), p);
	}

	private cursor(): TerminalCursor | null {
		const m = this.m;
		const type = "GhosttyRenderStateCursor";
		const p = this.scratch + SCRATCH.struct;
		m.initStruct(p, type);
		if (this.e.ghostty_render_state_get(this.renderState, this.k.rsCursor, p) !== SUCCESS) return null;
		if (!m.read(p, type, "visible") || !m.read(p, type, "viewport_has_value")) return null;
		const style = m.enumKey("GhosttyCursorStyle", m.read(p, type, "visual_style")) ?? "BLOCK";
		return {
			column: m.read(p, type, "viewport_x"),
			row: m.read(p, type, "viewport_y"),
			wide: m.read(p, type, "wide_tail") !== 0,
			shape: CURSOR_SHAPES[style] ?? "block",
			blinking: m.read(p, type, "blinking") !== 0,
		};
	}

	private scrollbar(): TerminalSnapshot["scrollback"] {
		const m = this.m;
		const type = "GhosttyTerminalScrollbar";
		const p = this.scratch + SCRATCH.struct;
		if (this.e.ghostty_terminal_get(this.terminal, this.k.termScrollbar, p) !== SUCCESS) {
			return { total: 0, offset: 0, length: this.rows };
		}
		return { total: m.read(p, type, "total"), offset: m.read(p, type, "offset"), length: m.read(p, type, "len") };
	}

	/** Frees every handle; later writes are ignored. */
	dispose(): void {
		if (this.disposed) return;
		this.disposed = true;
		const e = this.e;
		for (const event of Object.values(this.gestureEvents)) e.ghostty_selection_gesture_event_free(event);
		e.ghostty_selection_gesture_free(this.gesture, this.terminal);
		e.ghostty_mouse_event_free(this.mouseEvent);
		e.ghostty_mouse_encoder_free(this.mouseEncoder);
		e.ghostty_key_event_free(this.keyEvent);
		e.ghostty_key_encoder_free(this.keyEncoder);
		e.ghostty_render_state_row_cells_free(this.rowCells);
		e.ghostty_render_state_row_iterator_free(this.rowIterator);
		e.ghostty_render_state_free(this.renderState);
		e.ghostty_terminal_free(this.terminal);
		this.m.free(this.graphemeBuffer, this.graphemeCapacity);
		this.m.free(this.scratch, SCRATCH.size);
		if (this.replyCallback !== null) this.m.releaseCallback(this.replyCallback);
	}
}

function readRgb(bytes: Uint8Array, ptr: number): Rgb {
	return (bytes[ptr] << 16) | (bytes[ptr + 1] << 8) | bytes[ptr + 2];
}

function sameCursor(a: TerminalCursor | null, b: TerminalCursor | null): boolean {
	if (a === null || b === null) return a === b;
	return a.column === b.column && a.row === b.row && a.wide === b.wide && a.shape === b.shape && a.blinking === b.blinking;
}
