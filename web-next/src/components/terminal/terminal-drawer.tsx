"use client";

/*
 * The terminal drawer (#752): a collapsible bottom drawer on /sessions/[id]
 * holding a real shell into the session's live sandbox. Quiet affordances —
 * Ctrl+` and a small `>_` control above the status line — not persistent
 * chrome. A canvas over Ghostty's libghostty-vt wasm renders the PTY; the
 * transport behind it is the ticket exchange's verdict (ttyd WebSocket, or
 * the deterministic mock under AUTH_BYPASS), and its bytes reach the
 * terminal undecoded. The terminal mounts once and survives open/close and
 * reconnects, so scrollback and the tmux session read as one continuous
 * shell. A session with no live sandbox gets a calm note, not a fake shell.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { openMockPty } from "./mock-pty";
import {
	requestTerminalAccess,
	type TerminalConnection,
	type TerminalTransportHandlers,
} from "./transport";
import { openTtydSocket } from "./ttyd-transport";
import type { CanvasTerminal, CanvasTerminalTheme } from "./vt/canvas-terminal";

type Phase =
	| "idle"
	| "connecting"
	| "ready"
	| "no-sandbox"
	| "denied"
	| "failed"
	| "disconnected";

/** Folio-toned ANSI palettes, chosen from globals.css's token values. */
export const TERMINAL_THEMES = {
	light: {
		background: "#f1ede0",
		foreground: "#26221a",
		cursor: "#a15c31",
		selectionBackground: "rgba(161, 92, 49, 0.25)",
		black: "#26221a",
		red: "#9a4b33",
		green: "#3e6b36",
		yellow: "#8a6d1f",
		blue: "#4a6b8a",
		magenta: "#7d5a8a",
		cyan: "#3e7373",
		white: "#7a7261",
	},
	dark: {
		background: "#1b1913",
		foreground: "#eae4d6",
		cursor: "#d89a62",
		selectionBackground: "rgba(216, 154, 98, 0.3)",
		black: "#2a261e",
		red: "#ce9480",
		green: "#a9c896",
		yellow: "#d8c07a",
		blue: "#8fb0cc",
		magenta: "#c0a0cc",
		cyan: "#8fc0b8",
		white: "#a79e8c",
	},
} as const satisfies Record<string, CanvasTerminalTheme>;

/** A concrete stack: the canvas can't resolve CSS variables, so next/font's Plex Mono is out of reach. */
const FONT_FAMILY = 'ui-monospace, "SF Mono", Menlo, monospace';

export function TerminalDrawer({ sessionId }: { sessionId: string }) {
	const [open, setOpen] = useState(false);
	const [phase, setPhase] = useState<Phase>("idle");
	const [note, setNote] = useState("");
	const [ready, setReady] = useState(false);
	/** Transport the exchange resolved — shown honestly in the status bar. */
	const [mode, setMode] = useState<"ttyd" | "mock" | null>(null);

	const hostRef = useRef<HTMLDivElement>(null);
	const termRef = useRef<CanvasTerminal | null>(null);
	const pendingTermRef = useRef<Promise<CanvasTerminal | null> | null>(null);
	const connRef = useRef<TerminalConnection | null>(null);
	const connectingRef = useRef(false);
	const sawDataRef = useRef(false);
	const unmountedRef = useRef(false);

	/** Create the canvas terminal once, on first open; the binding and its wasm load here. */
	const ensureTerminal = useCallback((): Promise<CanvasTerminal | null> => {
		if (termRef.current) return Promise.resolve(termRef.current);
		pendingTermRef.current ??= (async () => {
			const host = hostRef.current;
			if (!host) return null;
			const { CanvasTerminal } = await import("./vt/canvas-terminal");
			if (unmountedRef.current) return null;
			const theme =
				document.documentElement.dataset.theme === "dark"
					? TERMINAL_THEMES.dark
					: TERMINAL_THEMES.light;
			const term = new CanvasTerminal(host, {
				fontSize: 13,
				fontFamily: FONT_FAMILY,
				theme,
				onData: (bytes) => connRef.current?.send(bytes),
				onResize: (columns, rows) => connRef.current?.resize(columns, rows),
			});
			try {
				await term.open();
			} catch (error) {
				term.dispose();
				throw error;
			}
			if (unmountedRef.current) {
				term.dispose();
				return null;
			}
			termRef.current = term;
			return term;
		})().finally(() => {
			pendingTermRef.current = null;
		});
		return pendingTermRef.current;
	}, []);

	const connect = useCallback(async () => {
		if (connRef.current || connectingRef.current) return;
		connectingRef.current = true;
		setPhase("connecting");
		try {
			let term: CanvasTerminal | null;
			try {
				term = await ensureTerminal();
			} catch (error) {
				setNote(error instanceof Error ? error.message : "the terminal failed to load");
				setPhase("failed");
				return;
			}
			if (!term) return;
			let access: Awaited<ReturnType<typeof requestTerminalAccess>>;
			try {
				access = await requestTerminalAccess(sessionId);
			} catch (error) {
				setNote(error instanceof Error ? error.message : "connection failed");
				setPhase("denied");
				return;
			}
			if (access.kind === "no-sandbox") {
				setNote(access.reason);
				setPhase("no-sandbox");
				return;
			}
			if (access.kind === "denied") {
				setNote(access.message);
				setPhase("denied");
				return;
			}
			const handlers: TerminalTransportHandlers = {
				onData: (bytes) => {
					term.write(bytes);
					if (!sawDataRef.current) {
						sawDataRef.current = true;
						// "Interactive" = the first PTY bytes are in a painted frame.
						requestAnimationFrame(() => setReady(true));
					}
				},
				onClose: (reason) => {
					connRef.current = null;
					sawDataRef.current = false;
					setReady(false);
					setNote(reason);
					setPhase("disconnected");
					term.write(`\r\n\x1b[2m[${reason}]\x1b[0m\r\n`);
				},
			};
			connRef.current =
				access.kind === "mock"
					? openMockPty(handlers)
					: openTtydSocket(access.wsUrl, handlers, {
							cols: term.columns,
							rows: term.rows,
						});
			setMode(access.kind);
			setPhase("ready");
			term.focus();
		} finally {
			connectingRef.current = false;
		}
	}, [ensureTerminal, sessionId]);

	const toggle = useCallback(() => {
		setOpen((wasOpen) => {
			const next = !wasOpen;
			if (next) {
				void connect();
				requestAnimationFrame(() => termRef.current?.focus());
			} else {
				termRef.current?.blur();
			}
			return next;
		});
	}, [connect]);

	// Ctrl+` — the conventional terminal toggle. Capture phase, so it works
	// even while the terminal itself has focus (its textarea's key handler
	// would otherwise turn the chord into bytes before a bubbling listener saw
	// it), and stopPropagation keeps the chord out of the shell.
	useEffect(() => {
		const onKeyDown = (event: KeyboardEvent) => {
			if (event.ctrlKey && (event.key === "`" || event.code === "Backquote")) {
				event.preventDefault();
				event.stopPropagation();
				toggle();
			}
		};
		window.addEventListener("keydown", onKeyDown, true);
		return () => window.removeEventListener("keydown", onKeyDown, true);
	}, [toggle]);

	// Dispose the terminal + transport with the session surface.
	useEffect(() => {
		unmountedRef.current = false;
		return () => {
			unmountedRef.current = true;
			connRef.current?.close();
			connRef.current = null;
			termRef.current?.dispose();
			termRef.current = null;
		};
	}, []);

	const statusLabel: Record<Phase, string> = {
		idle: "",
		connecting: "connecting…",
		ready:
			mode === "mock"
				? "mock PTY (AUTH_BYPASS)"
				: "attached to the session's sandbox",
		"no-sandbox": "no live sandbox",
		denied: "access denied",
		failed: "failed to load",
		disconnected: "disconnected",
	};
	const retryLabel: Partial<Record<Phase, string>> = {
		disconnected: "reconnect",
		"no-sandbox": "check again",
		failed: "try again",
	};

	return (
		<>
			<button
				type="button"
				data-testid="terminal-toggle"
				aria-label="Toggle terminal"
				title="Terminal (Ctrl+`)"
				onClick={toggle}
				className="fixed right-[16px] bottom-[42px] z-[16] rounded-[5px] px-1.5 py-1 font-mono text-stat leading-none text-faint opacity-70 transition-[opacity,color] duration-200 hover:text-ink hover:opacity-100"
			>
				&gt;_
			</button>
			<section
				data-testid="terminal-drawer"
				data-open={open ? "true" : "false"}
				data-ready={ready ? "true" : "false"}
				aria-label="Terminal"
				aria-hidden={!open}
				className={`fixed inset-x-0 bottom-0 z-30 border-t border-line-strong bg-status-bg shadow-palette transition-transform duration-200 ${
					open ? "translate-y-0" : "pointer-events-none translate-y-full"
				}`}
			>
				{/* A div, not <header>: the drawer bar is chrome, not a landmark —
				    and the page's one banner stays the masthead. */}
				<div className="flex h-[30px] items-center gap-2 border-b border-line px-3 font-mono text-stat tracking-[.03em] text-hint">
					<span className="text-muted">terminal</span>
					{phase !== "idle" && (
						<span data-testid="terminal-status">— {statusLabel[phase]}</span>
					)}
					{retryLabel[phase] && (
						<button
							type="button"
							onClick={() => void connect()}
							className="rounded-[5px] px-1.5 py-0.5 text-hint underline decoration-dotted underline-offset-2 hover:text-ink"
						>
							{retryLabel[phase]}
						</button>
					)}
					<button
						type="button"
						aria-label="Close terminal"
						title="Close terminal (Ctrl+`)"
						onClick={toggle}
						className="ml-auto rounded-[5px] px-1.5 py-1 leading-none text-faint opacity-70 hover:text-ink hover:opacity-100"
					>
						✕
					</button>
				</div>
				<div className="relative h-[38vh] min-h-[220px]">
					{/* CanvasTerminal mounts its canvas, input textarea and the
					    screen-reader mirror of the viewport ("Terminal screen") here. */}
					<div ref={hostRef} data-testid="terminal-host" className="h-full w-full px-2 py-1" />
					{(phase === "no-sandbox" || phase === "denied" || phase === "failed") && (
						<div
							data-testid="terminal-empty"
							className="absolute inset-0 flex flex-col items-center justify-center gap-2.5 bg-status-bg text-center"
						>
							<p className="font-serif text-body text-muted italic">
								{phase === "no-sandbox" ? "No live sandbox." : "Terminal unavailable."}
							</p>
							<p className="max-w-[52ch] font-mono text-caption text-hint">
								{note}
								{phase === "no-sandbox" &&
									" — start a turn and the terminal attaches to the same sandbox it runs in."}
							</p>
						</div>
					)}
				</div>
			</section>
		</>
	);
}
