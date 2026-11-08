"use client";

/*
 * The bench for the drawer's terminal: one CanvasTerminal over Ghostty's
 * release libghostty-vt wasm, fed from one source — the recorded agent-turn
 * fixture, the mock PTY, a live ttyd WebSocket, a synthetic stress stream, or
 * the parity screen (scrollback, an OSC 8 link, a blinking bar cursor) the
 * e2e spec drives. It records per-frame cost, replays a fixed matrix of
 * synthetic key, IME and paste events into the input layer, and publishes
 * everything as JSON in #bench-metrics.
 *
 * URL: ?source=fixture|mock|ttyd|stress|parity
 *      &optionAsAlt=false|true|left|right &ws=ws://127.0.0.1:7681/ws &mb=2 &chunk=16384
 */
import { useEffect, useRef, useState } from "react";
import { openMockPty } from "@/components/terminal/mock-pty";
import { TERMINAL_THEMES } from "@/components/terminal/terminal-drawer";
import type { TerminalConnection } from "@/components/terminal/transport";
import { openTtydSocket } from "@/components/terminal/ttyd-transport";
import { CanvasTerminal, type MacOptionAsAlt } from "@/components/terminal/vt/canvas-terminal";

type Source = "fixture" | "mock" | "ttyd" | "stress" | "parity";

const theme = TERMINAL_THEMES.light;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function params() {
	const q = new URLSearchParams(window.location.search);
	return {
		source: (q.get("source") ?? "fixture") as Source,
		optionAsAlt: (q.get("optionAsAlt") ?? "false") as MacOptionAsAlt,
		ws: q.get("ws") ?? "ws://127.0.0.1:7681/ws",
		mb: Number(q.get("mb") ?? "2"),
		chunk: Number(q.get("chunk") ?? "16384"),
	};
}

/** What the parity e2e drives: scrollback to select across, an OSC 8 link, a blinking bar cursor. */
export const PARITY_SCREEN = [
	...Array.from({ length: 40 }, (_, i) => `history ${String(i).padStart(2, "0")}\r\n`),
	"links: \x1b]8;;https://ghostty.org/docs\x1b\\ghostty.org/docs\x1b]8;;\x1b\\ and plain text\r\n",
	"\x1b[1mparity\x1b[0m selection · mouse · focus · links · cursor · IME\r\n",
	"\x1b[5 q$ ",
].join("");

/** Deterministic agent-ish output: colored log lines, a redrawn progress bar, wide text. */
export function stressStream(totalBytes: number): Uint8Array {
	const parts: string[] = [];
	let size = 0;
	let i = 0;
	while (size < totalBytes) {
		const line =
			i % 50 === 0
				? `\r\x1b[K\x1b[2m[${i}/∞]\x1b[0m \x1b[33m${"█".repeat(i % 40)}\x1b[0m\r\n`
				: `\x1b[32m✔\x1b[0m \x1b[1mtest ${i}\x1b[0m \x1b[38;5;${i % 256}mcolor ${i % 256}\x1b[0m \x1b[38;2;${i % 255};120;200mtruecolor\x1b[0m 完成 ${"·".repeat(i % 30)}\r\n`;
		parts.push(line);
		size += line.length;
		i++;
	}
	return encoder.encode(parts.join(""));
}

function percentile(values: number[], p: number): number {
	if (values.length === 0) return 0;
	const sorted = [...values].sort((a, b) => a - b);
	return Number(sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))].toFixed(2));
}

function summarize(values: number[]) {
	return {
		n: values.length,
		p50: percentile(values, 50),
		p95: percentile(values, 95),
		max: percentile(values, 100),
		mean: values.length ? Number((values.reduce((a, b) => a + b, 0) / values.length).toFixed(2)) : 0,
	};
}

/** What the terminal sent and which links it opened, for the e2e spec to read. */
export interface TerminalVtProbe {
	vt: CanvasTerminal;
	sent: string[];
	links: string[];
}

declare global {
	interface Window {
		__terminalVt?: TerminalVtProbe;
	}
}

interface KeyCase {
	label: string;
	init?: KeyboardEventInit & { key: string; code: string };
	setup?: string;
	composition?: string;
	paste?: string;
	/** Bytes from the program whose reply the terminal owes, captured like input. */
	query?: string;
}

/** Synthetic input replayed into the terminal; `setup` bytes put it in a mode first. */
const KEY_CASES: KeyCase[] = [
	{ label: "a", init: { key: "a", code: "KeyA" } },
	{ label: "Shift+A", init: { key: "A", code: "KeyA", shiftKey: true } },
	{ label: "Enter", init: { key: "Enter", code: "Enter" } },
	{ label: "Backspace", init: { key: "Backspace", code: "Backspace" } },
	{ label: "Tab", init: { key: "Tab", code: "Tab" } },
	{ label: "Shift+Tab", init: { key: "Tab", code: "Tab", shiftKey: true } },
	{ label: "Escape", init: { key: "Escape", code: "Escape" } },
	{ label: "ArrowUp", init: { key: "ArrowUp", code: "ArrowUp" } },
	{ label: "ArrowUp (DECCKM on)", init: { key: "ArrowUp", code: "ArrowUp" }, setup: "\x1b[?1h" },
	{ label: "Ctrl+C", init: { key: "c", code: "KeyC", ctrlKey: true } },
	{ label: "Ctrl+D", init: { key: "d", code: "KeyD", ctrlKey: true } },
	{ label: "Ctrl+[", init: { key: "[", code: "BracketLeft", ctrlKey: true } },
	{ label: "Ctrl+Space", init: { key: " ", code: "Space", ctrlKey: true } },
	{ label: "Ctrl+/", init: { key: "/", code: "Slash", ctrlKey: true } },
	{ label: "Alt+B (key ∫, macOS)", init: { key: "∫", code: "KeyB", altKey: true } },
	{ label: "Alt+ArrowLeft", init: { key: "ArrowLeft", code: "ArrowLeft", altKey: true } },
	{ label: "Ctrl+ArrowLeft", init: { key: "ArrowLeft", code: "ArrowLeft", ctrlKey: true } },
	{ label: "Shift+Enter", init: { key: "Enter", code: "Enter", shiftKey: true } },
	{ label: "Home", init: { key: "Home", code: "Home" } },
	{ label: "PageUp", init: { key: "PageUp", code: "PageUp" } },
	{ label: "Delete", init: { key: "Delete", code: "Delete" } },
	{ label: "F1", init: { key: "F1", code: "F1" } },
	{ label: "F5", init: { key: "F5", code: "F5" } },
	{ label: "F12", init: { key: "F12", code: "F12" } },
	{ label: "Ctrl+C (kitty flags 1)", init: { key: "c", code: "KeyC", ctrlKey: true }, setup: "\x1b[>1u" },
	{ label: "Escape (kitty flags 1)", init: { key: "Escape", code: "Escape" }, setup: "\x1b[>1u" },
	{ label: "IME commit 日本語", composition: "日本語" },
	{ label: "paste ls⎋[201~id⏎ (plain)", paste: "ls\x1b[201~id\r" },
	{ label: "paste ls⎋[201~id⏎ (2004 on)", paste: "ls\x1b[201~id\r", setup: "\x1b[?2004h" },
	{ label: "paste a^Cb (2004 on)", paste: "a\x03b", setup: "\x1b[?2004h" },
	{ label: "reply to DA1 ⎋[c", query: "\x1b[c" },
	{ label: "reply to CPR ⎋[6n", query: "\x1b[H\x1b[6n" },
];

const RESET_MODES = "\x1b[?1l\x1b[?2004l\x1b[<u\x1b[<u";

function show(data: string): string {
	return JSON.stringify(data).slice(1, -1).replace(/\\u001b/g, "⎋");
}

async function runKeyMatrix(vt: CanvasTerminal, capture: (fn: (data: string) => void) => void): Promise<Record<string, string>> {
	const results: Record<string, string> = {};
	let captured = "";
	capture((d) => {
		captured += d;
	});
	const target = vt.textarea;
	for (const c of KEY_CASES) {
		vt.write(RESET_MODES + (c.setup ?? ""));
		await new Promise((r) => requestAnimationFrame(() => r(null)));
		captured = "";
		target.focus();
		if (c.query) {
			vt.write(c.query);
		} else if (c.init) {
			target.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...c.init }));
		} else if (c.composition) {
			target.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true, data: "" }));
			target.dispatchEvent(new CompositionEvent("compositionupdate", { bubbles: true, data: c.composition }));
			target.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: c.composition }));
		} else if (c.paste) {
			const dt = new DataTransfer();
			dt.setData("text/plain", c.paste);
			target.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: dt }));
		}
		await new Promise((r) => setTimeout(r, 20));
		results[c.label] = show(captured);
	}
	vt.write(RESET_MODES);
	return results;
}

export function TerminalVtBench() {
	const host = useRef<HTMLDivElement>(null);
	const [metrics, setMetrics] = useState<Record<string, unknown>>({ phase: "loading" });
	const [matrix, setMatrix] = useState<Record<string, string> | null>(null);
	const vtRef = useRef<CanvasTerminal | null>(null);
	const connRef = useRef<TerminalConnection | null>(null);
	const captureRef = useRef<((data: string) => void) | null>(null);

	useEffect(() => {
		const p = params();
		let cancelled = false;
		const sent: string[] = [];
		const links: string[] = [];
		const vt = new CanvasTerminal(host.current!, {
			macOptionAsAlt: p.optionAsAlt,
			onOpenLink: (uri) => links.push(uri),
			fontSize: 13,
			theme,
			onData: (bytes) => {
				const data = decoder.decode(bytes);
				sent.push(data);
				captureRef.current?.(data);
				connRef.current?.send(bytes);
			},
			onResize: (columns, rows) => connRef.current?.resize(columns, rows),
		});

		(async () => {
			try {
				await vt.open();
			} catch (error) {
				setMetrics({ phase: "error", error: String(error) });
				return;
			}
			if (cancelled) return;
			vtRef.current = vt;
			window.__terminalVt = { vt, sent, links };
			const base = {
				source: p.source,
				optionAsAlt: p.optionAsAlt,
				vtVersion: vt.version,
				size: { columns: vt.columns, rows: vt.rows },
			};

			if (p.source === "fixture") {
				const bytes = new Uint8Array(await (await fetch("/dev/terminal-vt/agent-turn.vt")).arrayBuffer());
				for (let i = 0; i < bytes.length; i += 24) {
					vt.write(bytes.subarray(i, i + 24));
					await new Promise((r) => requestAnimationFrame(() => r(null)));
				}
				await new Promise((r) => setTimeout(r, 200));
				setMetrics({ ...base, phase: "done", bytes: bytes.length, text: vt.text() });
			} else if (p.source === "parity") {
				vt.write(PARITY_SCREEN);
				await new Promise((r) => setTimeout(r, 200));
				setMetrics({ ...base, phase: "done", bytes: PARITY_SCREEN.length });
			} else if (p.source === "stress") {
				const bytes = stressStream(p.mb * 1024 * 1024);
				const intervals: number[] = [];
				const writeMs: number[] = [];
				let last = performance.now();
				const start = last;
				for (let i = 0; i < bytes.length; i += p.chunk) {
					const t0 = performance.now();
					vt.write(bytes.subarray(i, i + p.chunk));
					writeMs.push(performance.now() - t0);
					await new Promise((r) => requestAnimationFrame(() => r(null)));
					const now = performance.now();
					intervals.push(now - last);
					last = now;
				}
				await new Promise((r) => setTimeout(r, 300));
				setMetrics({
					...base,
					phase: "done",
					bytes: bytes.length,
					chunk: p.chunk,
					drainMs: Number((last - start).toFixed(1)),
					writeMs: summarize(writeMs),
					frameIntervalMs: summarize(intervals),
					snapshotMs: summarize(vt.frames.map((f) => f.snapshotMs)),
					paintMs: summarize(vt.frames.map((f) => f.paintMs)),
				});
			} else {
				const handlers = {
					onData: (bytes: Uint8Array) => vt.write(bytes),
					onClose: (reason: string) => vt.write(`\r\n\x1b[2m[${reason}]\x1b[0m\r\n`),
				};
				connRef.current =
					p.source === "mock" ? openMockPty(handlers) : openTtydSocket(p.ws, handlers, { cols: vt.columns, rows: vt.rows });
				vt.focus();
				setMetrics({ ...base, phase: "live" });
			}
		})();

		return () => {
			cancelled = true;
			connRef.current?.close();
			connRef.current = null;
			vtRef.current = null;
			vt.dispose();
		};
	}, []);

	const runMatrix = async () => {
		const vt = vtRef.current;
		if (!vt) return;
		const saved = connRef.current;
		connRef.current = null;
		setMatrix(
			await runKeyMatrix(vt, (fn) => {
				captureRef.current = fn;
			}),
		);
		captureRef.current = null;
		connRef.current = saved;
	};

	return (
		<main className="space-y-4 p-6 font-mono text-caption" style={{ background: theme.background, color: theme.foreground }}>
			<h1 className="text-body">terminal-vt bench — libghostty-vt {String(metrics.vtVersion ?? "")} release wasm + canvas</h1>
			<div
				data-testid="pane-vt"
				ref={host}
				className="relative h-[380px] w-[620px] overflow-hidden rounded border border-line-strong p-1"
				style={{ background: theme.background }}
			/>
			<button type="button" data-testid="run-matrix" onClick={() => void runMatrix()} className="rounded border border-line px-2 py-1">
				run input matrix
			</button>
			{matrix && (
				<table data-testid="matrix" className="border-collapse">
					<thead>
						<tr>
							<th className="pr-4 text-left">input</th>
							<th className="pr-4 text-left">bytes sent</th>
						</tr>
					</thead>
					<tbody>
						{Object.entries(matrix).map(([label, bytes]) => (
							<tr key={label}>
								<td className="pr-4">{label}</td>
								<td className="pr-4">{bytes || "∅"}</td>
							</tr>
						))}
					</tbody>
				</table>
			)}
			<pre id="bench-metrics" data-testid="bench-metrics" className="whitespace-pre-wrap">
				{JSON.stringify(matrix ? { ...metrics, matrix } : metrics, null, 2)}
			</pre>
		</main>
	);
}
