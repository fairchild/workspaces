"use client";

/*
 * The terminal drawer (#752): a collapsible bottom drawer on /sessions/[id]
 * holding a real shell into the session's live sandbox. Quiet affordances —
 * Ctrl+` and a small `>_` control above the status line — not persistent
 * chrome. ghostty-web renders the PTY; the transport behind it is the ticket
 * exchange's verdict (ttyd WebSocket, or the deterministic mock under
 * AUTH_BYPASS). The terminal mounts once and survives open/close and
 * reconnects, so scrollback and the tmux session read as one continuous
 * shell. A session with no live sandbox gets a calm note, not a fake shell.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { openMockPty } from "./mock-pty";
import {
	requestTerminalAccess,
	type TerminalConnection,
} from "./transport";
import { openTtydSocket } from "./ttyd-transport";

type GhosttyTerminal = import("ghostty-web").Terminal;
type GhosttyFitAddon = import("ghostty-web").FitAddon;

type Phase =
	| "idle"
	| "connecting"
	| "ready"
	| "no-sandbox"
	| "denied"
	| "disconnected";

/** Folio-toned ANSI palettes, chosen from globals.css's token values. */
const TERMINAL_THEMES = {
	light: {
		background: "#f1ede0",
		foreground: "#26221a",
		cursor: "#a15c31",
		selectionBackground: "#ebdfc8",
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
} as const;

/** Cap on the hidden plain-text mirror of PTY output (tests + screen readers). */
const TRANSCRIPT_CAP = 8_000;

const stripControl = (text: string) =>
	text
		.replace(/\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07/g, "")
		.replace(/[\r\x07]/g, "");

export function TerminalDrawer({ sessionId }: { sessionId: string }) {
	const [open, setOpen] = useState(false);
	const [phase, setPhase] = useState<Phase>("idle");
	const [note, setNote] = useState("");
	const [ready, setReady] = useState(false);
	/** Transport the exchange resolved — shown honestly in the status bar. */
	const [mode, setMode] = useState<"ttyd" | "mock" | null>(null);

	const hostRef = useRef<HTMLDivElement>(null);
	const transcriptRef = useRef<HTMLDivElement>(null);
	const termRef = useRef<GhosttyTerminal | null>(null);
	const fitRef = useRef<GhosttyFitAddon | null>(null);
	const connRef = useRef<TerminalConnection | null>(null);
	const connectingRef = useRef(false);
	const sawDataRef = useRef(false);

	/** Create the ghostty-web terminal once, on first open. */
	const ensureTerminal = useCallback(async (): Promise<GhosttyTerminal | null> => {
		if (termRef.current) return termRef.current;
		const host = hostRef.current;
		if (!host) return null;
		const { init, Terminal, FitAddon } = await import("ghostty-web");
		await init();
		if (termRef.current || !hostRef.current) return termRef.current;
		const theme =
			document.documentElement.dataset.theme === "dark"
				? TERMINAL_THEMES.dark
				: TERMINAL_THEMES.light;
		const term = new Terminal({
			cursorBlink: true,
			fontSize: 13,
			// A concrete stack: the canvas renderer can't resolve CSS variables,
			// so the next/font-registered Plex Mono is out of reach here.
			fontFamily: 'ui-monospace, "SF Mono", Menlo, monospace',
			theme,
		});
		const fit = new FitAddon();
		term.loadAddon(fit);
		term.onData((data) => connRef.current?.send(data));
		term.onResize(({ cols, rows }) => connRef.current?.resize(cols, rows));
		term.open(host);
		termRef.current = term;
		fitRef.current = fit;
		requestAnimationFrame(() => {
			try {
				fit.fit();
				fit.observeResize();
			} catch {
				// host not laid out yet; observeResize catches the next pass
			}
		});
		return term;
	}, []);

	const connect = useCallback(async () => {
		if (connRef.current || connectingRef.current) return;
		connectingRef.current = true;
		setPhase("connecting");
		try {
			const term = await ensureTerminal();
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
			const handlers = {
				onData: (text: string) => {
					term.write(text);
					const mirror = transcriptRef.current;
					if (mirror) {
						mirror.textContent = (
							(mirror.textContent ?? "") + stripControl(text)
						).slice(-TRANSCRIPT_CAP);
					}
					if (!sawDataRef.current) {
						sawDataRef.current = true;
						// "Interactive" = the first PTY bytes are in a painted frame.
						requestAnimationFrame(() => setReady(true));
					}
				},
				onClose: (reason: string) => {
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
							cols: term.cols,
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
				requestAnimationFrame(() => {
					try {
						fitRef.current?.fit();
					} catch {
						// not laid out yet
					}
					termRef.current?.focus();
				});
			} else {
				termRef.current?.blur();
			}
			return next;
		});
	}, [connect]);

	// Ctrl+` — the conventional terminal toggle. Capture phase, so it works
	// even while the terminal itself has focus (ghostty's key handler would
	// otherwise consume the event before a bubbling listener saw it), and
	// stopPropagation keeps the chord out of the shell.
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
		return () => {
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
		disconnected: "disconnected",
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
				<div className="flex h-[30px] items-center gap-2 border-b border-line px-3 font-mono text-stat tracking-[.03em] text-faint">
					<span className="text-muted">terminal</span>
					{phase !== "idle" && (
						<span data-testid="terminal-status">— {statusLabel[phase]}</span>
					)}
					{(phase === "disconnected" || phase === "no-sandbox") && (
						<button
							type="button"
							onClick={() => void connect()}
							className="rounded-[5px] px-1.5 py-0.5 text-faint underline decoration-dotted underline-offset-2 hover:text-ink"
						>
							{phase === "disconnected" ? "reconnect" : "check again"}
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
					<div ref={hostRef} className="h-full w-full px-2 py-1" />
					{(phase === "no-sandbox" || phase === "denied") && (
						<div
							data-testid="terminal-empty"
							className="absolute inset-0 flex flex-col items-center justify-center gap-2.5 bg-status-bg text-center"
						>
							<p className="font-serif text-body text-muted italic">
								{phase === "no-sandbox" ? "No live sandbox." : "Terminal unavailable."}
							</p>
							<p className="max-w-[52ch] font-mono text-caption text-faint">
								{note}
								{phase === "no-sandbox" &&
									" — start a turn and the terminal attaches to the same sandbox it runs in."}
							</p>
						</div>
					)}
				</div>
				{/* Plain-text mirror of PTY output: assertable by tests, readable by
				    screen readers; the canvas above is neither. */}
				<div
					ref={transcriptRef}
					data-testid="terminal-transcript"
					aria-live="off"
					className="sr-only"
				/>
			</section>
		</>
	);
}
