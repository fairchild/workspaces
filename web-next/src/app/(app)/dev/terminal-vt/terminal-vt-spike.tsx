"use client";

/*
 * The #1846 spike harness. Two panes of equal size — ghostty-web 0.4.0 (the
 * drawer's renderer today) and a canvas over Ghostty's release
 * libghostty-vt 1.0 wasm — fed identical bytes from one source: the recorded
 * agent-turn fixture, the mock PTY, a live ttyd WebSocket, or a synthetic
 * stress stream. It records per-frame cost, replays a fixed matrix of
 * synthetic key, IME and paste events into both input layers, and publishes
 * everything as JSON in #spike-metrics for the evidence run to read.
 *
 * URL: ?source=fixture|mock|ttyd|stress &pane=both|web|vt &build=fast|small
 *      &ws=ws://127.0.0.1:7681/ws &mb=2
 */
import { useEffect, useRef, useState } from "react";
import { openMockPty } from "@/components/terminal/mock-pty";
import { TERMINAL_THEMES } from "@/components/terminal/terminal-drawer";
import type { TerminalConnection } from "@/components/terminal/transport";
import { openTtydSocket } from "@/components/terminal/ttyd-transport";
import { CanvasTerminal } from "@/components/terminal/vt/canvas-terminal";
import type { VtBuild } from "@/components/terminal/vt/ghostty-vt";

type GhosttyTerminal = import("ghostty-web").Terminal;
type Source = "fixture" | "mock" | "ttyd" | "stress";
type Pane = "both" | "web" | "vt";

interface Sink {
	name: "ghostty-web" | "ghostty-vt";
	write(bytes: Uint8Array): void;
	textarea(): HTMLElement | null;
	setOnData(fn: (data: string) => void): void;
	frameStats(): { renderMs: number[] };
	text(): string;
	size(): { columns: number; rows: number };
}

const FONT_FAMILY = 'ui-monospace, "SF Mono", Menlo, monospace';
const theme = TERMINAL_THEMES.light;

function params() {
	const q = new URLSearchParams(window.location.search);
	return {
		source: (q.get("source") ?? "fixture") as Source,
		pane: (q.get("pane") ?? "both") as Pane,
		build: (q.get("build") ?? "fast") as VtBuild,
		ws: q.get("ws") ?? "ws://127.0.0.1:7681/ws",
		mb: Number(q.get("mb") ?? "2"),
		chunk: Number(q.get("chunk") ?? "16384"),
	};
}

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
	return new TextEncoder().encode(parts.join(""));
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

async function mountGhosttyWeb(host: HTMLElement, onData: (d: string) => void): Promise<Sink> {
	const { init, Terminal, FitAddon } = await import("ghostty-web");
	await init();
	const term: GhosttyTerminal = new Terminal({ cursorBlink: false, fontSize: 13, fontFamily: FONT_FAMILY, theme });
	const fit = new FitAddon();
	term.loadAddon(fit);
	let handler = onData;
	term.onData((d) => handler(d));
	term.open(host);
	fit.fit();
	const renderMs: number[] = [];
	const renderer = (term as unknown as { renderer?: { render: (...a: unknown[]) => void } }).renderer;
	if (renderer) {
		const original = renderer.render.bind(renderer);
		renderer.render = (...args: unknown[]) => {
			const t0 = performance.now();
			original(...args);
			renderMs.push(performance.now() - t0);
		};
	}
	const decoder = new TextDecoder();
	return {
		name: "ghostty-web",
		write: (bytes) => term.write(decoder.decode(bytes, { stream: true })),
		textarea: () => (term as unknown as { textarea?: HTMLElement }).textarea ?? null,
		setOnData: (fn) => {
			handler = fn;
		},
		frameStats: () => ({ renderMs }),
		text: () => {
			const buffer = term.buffer.active;
			const lines: string[] = [];
			for (let y = 0; y < term.rows; y++) {
				lines.push(buffer.getLine(buffer.viewportY + y)?.translateToString(true) ?? "");
			}
			return lines.join("\n");
		},
		size: () => ({ columns: term.cols, rows: term.rows }),
	};
}

async function mountGhosttyVt(
	host: HTMLElement,
	build: VtBuild,
	onData: (d: string) => void,
	onResize: (columns: number, rows: number) => void,
): Promise<Sink & { vt: CanvasTerminal }> {
	const decoder = new TextDecoder();
	let handler = onData;
	const vt = new CanvasTerminal(host, {
		build,
		fontSize: 13,
		fontFamily: FONT_FAMILY,
		theme,
		onData: (bytes) => handler(decoder.decode(bytes)),
		onResize,
	});
	await vt.open();
	return {
		name: "ghostty-vt",
		vt,
		write: (bytes) => vt.write(bytes),
		textarea: () => vt.textarea,
		setOnData: (fn) => {
			handler = fn;
		},
		frameStats: () => ({ renderMs: vt.frames.map((f) => f.snapshotMs + f.paintMs) }),
		text: () => vt.text(),
		size: () => ({ columns: vt.columns, rows: vt.rows }),
	};
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

/** Synthetic input replayed into both panes; `setup` bytes put the terminal in a mode first. */
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

async function runKeyMatrix(sinks: Sink[]): Promise<Record<string, Record<string, string>>> {
	const results: Record<string, Record<string, string>> = {};
	for (const c of KEY_CASES) results[c.label] = {};
	for (const sink of sinks) {
		const target = sink.textarea();
		if (!target) continue;
		let captured = "";
		sink.setOnData((d) => {
			captured += d;
		});
		for (const c of KEY_CASES) {
			sink.write(new TextEncoder().encode(RESET_MODES + (c.setup ?? "")));
			await new Promise((r) => requestAnimationFrame(() => r(null)));
			captured = "";
			target.focus();
			if (c.query) {
				sink.write(new TextEncoder().encode(c.query));
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
			results[c.label][sink.name] = show(captured);
		}
		sink.write(new TextEncoder().encode(RESET_MODES));
	}
	return results;
}

export function TerminalVtSpike() {
	const webHost = useRef<HTMLDivElement>(null);
	const vtHost = useRef<HTMLDivElement>(null);
	const [metrics, setMetrics] = useState<Record<string, unknown>>({ phase: "loading" });
	const [matrix, setMatrix] = useState<Record<string, Record<string, string>> | null>(null);
	const sinksRef = useRef<Sink[]>([]);
	const connRef = useRef<TerminalConnection | null>(null);

	useEffect(() => {
		const p = params();
		let cancelled = false;
		const sinks: Sink[] = [];
		const send = (data: string) => connRef.current?.send(data);

		(async () => {
			try {
				if (p.pane !== "vt" && webHost.current) sinks.push(await mountGhosttyWeb(webHost.current, send));
				if (p.pane !== "web" && vtHost.current) sinks.push(
						await mountGhosttyVt(vtHost.current, p.build, send, (columns, rows) => connRef.current?.resize(columns, rows)),
					);
			} catch (error) {
				setMetrics({ phase: "error", error: String(error) });
				return;
			}
			if (cancelled) return;
			sinksRef.current = sinks;
			const vtSink = sinks.find((s) => s.name === "ghostty-vt") as (Sink & { vt: CanvasTerminal }) | undefined;
			const encoder = new TextEncoder();
			const fanOut = (bytes: Uint8Array) => {
				for (const sink of sinks) sink.write(bytes);
			};
			const base = {
				source: p.source,
				pane: p.pane,
				build: p.build,
				vtVersion: vtSink?.vt.version ?? null,
				sizes: Object.fromEntries(sinks.map((s) => [s.name, s.size()])),
			};

			if (p.source === "fixture") {
				const bytes = new Uint8Array(await (await fetch("/dev/terminal-vt/agent-turn.vt")).arrayBuffer());
				for (let i = 0; i < bytes.length; i += 24) {
					fanOut(bytes.subarray(i, i + 24));
					await new Promise((r) => requestAnimationFrame(() => r(null)));
				}
				await new Promise((r) => setTimeout(r, 200));
				setMetrics({ ...base, phase: "done", bytes: bytes.length, text: Object.fromEntries(sinks.map((s) => [s.name, s.text()])) });
			} else if (p.source === "stress") {
				const bytes = stressStream(p.mb * 1024 * 1024);
				const intervals: number[] = [];
				const writeMs: number[] = [];
				let last = performance.now();
				const start = last;
				for (let i = 0; i < bytes.length; i += p.chunk) {
					const t0 = performance.now();
					fanOut(bytes.subarray(i, i + p.chunk));
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
					renderMs: Object.fromEntries(sinks.map((s) => [s.name, summarize(s.frameStats().renderMs)])),
					vtSplit: vtSink
						? {
								snapshotMs: summarize(vtSink.vt.frames.map((f) => f.snapshotMs)),
								paintMs: summarize(vtSink.vt.frames.map((f) => f.paintMs)),
							}
						: null,
				});
			} else {
				const handlers = {
					onData: (text: string) => fanOut(encoder.encode(text)),
					onClose: (reason: string) => fanOut(encoder.encode(`\r\n\x1b[2m[${reason}]\x1b[0m\r\n`)),
				};
				const size = (vtSink ?? sinks[0]).size();
				connRef.current =
					p.source === "mock" ? openMockPty(handlers) : openTtydSocket(p.ws, handlers, { cols: size.columns, rows: size.rows });
				if (vtSink) {
					vtSink.vt.textarea.focus();
				}
				setMetrics({ ...base, phase: "live" });
			}
		})();

		return () => {
			cancelled = true;
			connRef.current?.close();
			connRef.current = null;
		};
	}, []);

	const runMatrix = async () => {
		const sinks = sinksRef.current;
		setMatrix(await runKeyMatrix(sinks));
		for (const sink of sinks) sink.setOnData((d) => connRef.current?.send(d));
	};

	const paneClass = "relative h-[380px] w-[620px] overflow-hidden rounded border border-line-strong p-1";
	return (
		<main className="space-y-4 p-6 font-mono text-caption" style={{ background: theme.background, color: theme.foreground }}>
			<h1 className="text-body">terminal-vt spike (#1846)</h1>
			<div className="flex flex-wrap gap-6">
				<section>
					<h2 className="mb-1 text-hint">ghostty-web 0.4.0 (Ghostty 5714ed07 + wasm patch)</h2>
					<div data-testid="pane-web" ref={webHost} className={paneClass} style={{ background: theme.background }} />
				</section>
				<section>
					<h2 className="mb-1 text-hint">libghostty-vt {String(metrics.vtVersion ?? "1.0.0")} release wasm + spike canvas</h2>
					<div data-testid="pane-vt" ref={vtHost} className={paneClass} style={{ background: theme.background }} />
				</section>
			</div>
			<button type="button" data-testid="run-matrix" onClick={() => void runMatrix()} className="rounded border border-line px-2 py-1">
				run input matrix
			</button>
			{matrix && (
				<table data-testid="matrix" className="border-collapse">
					<thead>
						<tr>
							<th className="pr-4 text-left">input</th>
							<th className="pr-4 text-left">ghostty-web</th>
							<th className="pr-4 text-left">ghostty-vt</th>
						</tr>
					</thead>
					<tbody>
						{Object.entries(matrix).map(([label, row]) => (
							<tr key={label} className={row["ghostty-web"] === row["ghostty-vt"] ? "" : "bg-[#ebdfc8]"}>
								<td className="pr-4">{label}</td>
								<td className="pr-4">{row["ghostty-web"] || "∅"}</td>
								<td className="pr-4">{row["ghostty-vt"] || "∅"}</td>
							</tr>
						))}
					</tbody>
				</table>
			)}
			<pre id="spike-metrics" data-testid="spike-metrics" className="whitespace-pre-wrap">
				{JSON.stringify(matrix ? { ...metrics, matrix } : metrics, null, 2)}
			</pre>
		</main>
	);
}
