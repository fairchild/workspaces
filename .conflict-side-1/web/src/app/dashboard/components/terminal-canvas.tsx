"use client";

import { useEffect, useRef } from "react";
import styles from "./terminal-panel.module.css";

interface TerminalCanvasProps {
	/**
	 * Stable identity for this terminal across sandbox restarts. When the
	 * underlying sandbox is paused and resumed, the sandbox ID changes but
	 * the agent name stays the same — keying by agentName lets us preserve
	 * the ghostty-web instance (and its scrollback) across the round-trip.
	 */
	agentName: string;
	/** ttyd WebSocket URL with the auth path token already included */
	terminalUrl: string;
	/** Whether this canvas is currently the active sub-tab */
	active: boolean;
}

type GhosttyTerminal = import("ghostty-web").Terminal;
type GhosttyFitAddon = import("ghostty-web").FitAddon;

interface MountedState {
	term: GhosttyTerminal;
	fitAddon: GhosttyFitAddon;
	ws: WebSocket | null;
	disposed: boolean;
	currentUrl: string | null;
	reconnectTimer: number | null;
}

/**
 * One ghostty-web canvas wired up to one ttyd WebSocket. The terminal
 * persists across:
 *   - sub-tab switches (toggled via display: none)
 *   - sandbox restart (paused → resumed): the WebSocket reconnects to the
 *     new URL but the canvas, scrollback, and process state in the user's
 *     mental model are continuous
 *
 * Two effects:
 *   - Mount effect (deps: agentName): creates the term + canvas, runs once
 *     per agent. Tear-down disposes the term.
 *   - WebSocket effect (deps: terminalUrl): connects/reconnects the WS.
 *     The term lives on while the WS is being torn down and re-established.
 */
export function TerminalCanvas({
	agentName,
	terminalUrl,
	active,
}: TerminalCanvasProps) {
	const containerRef = useRef<HTMLDivElement>(null);
	const stateRef = useRef<MountedState | null>(null);

	// Mount effect — creates the ghostty-web canvas once per agent. Does
	// NOT depend on terminalUrl, so a sandbox restart doesn't tear down
	// the canvas.
	useEffect(() => {
		const container = containerRef.current;
		if (!container) return;

		// agentName is used both as the effect's identity key (re-mount on
		// agent change) and to write a local banner so the user can see
		// which agent's terminal they're looking at without checking the
		// status bar.
		const banner = `# ${agentName}\r\n`;
		let cancelled = false;

		async function setup() {
			const { init, Terminal, FitAddon } = await import("ghostty-web");
			await init();
			if (cancelled || !container) return;

			const fitAddon = new FitAddon();
			const term = new Terminal({
				cursorBlink: true,
				fontSize: 14,
				fontFamily: 'Monaco, Menlo, "Courier New", ui-monospace, monospace',
				theme: {
					background: "#0e1117",
					foreground: "#d4dae8",
					cursor: "#a6ffdf",
					selectionBackground: "#242a3a",
					black: "#0e1117",
					red: "#ff6b6b",
					green: "#a6ffdf",
					yellow: "#ffd93d",
					blue: "#6c9eff",
					magenta: "#c084fc",
					cyan: "#67e8f9",
					white: "#d4dae8",
				},
			});

			const state: MountedState = {
				term,
				fitAddon,
				ws: null,
				disposed: false,
				currentUrl: null,
				reconnectTimer: null,
			};
			stateRef.current = state;

			term.loadAddon(fitAddon);

			// Resize handler MUST be registered before fit so the resize event
			// from the initial fit() reaches sendResize() and ttyd gets the
			// correct dimensions in its first frame after the auth handshake.
			const sendResize = (cols: number, rows: number) => {
				if (state.ws?.readyState !== WebSocket.OPEN) return;
				const enc = new TextEncoder();
				const payload = enc.encode(JSON.stringify({ columns: cols, rows }));
				const frame = new Uint8Array(payload.length + 1);
				frame[0] = "1".charCodeAt(0);
				frame.set(payload, 1);
				state.ws.send(frame);
			};
			term.onResize(({ cols, rows }) => sendResize(cols, rows));

			// Wire keystrokes to the live WebSocket. The handler stays on the
			// term forever — it just sends to whatever the current WS is.
			const encoder = new TextEncoder();
			term.onData((data) => {
				if (state.ws?.readyState !== WebSocket.OPEN) return;
				const payload = encoder.encode(data);
				const frame = new Uint8Array(payload.length + 1);
				frame[0] = "0".charCodeAt(0);
				frame.set(payload, 1);
				state.ws.send(frame);
			});

			term.open(container);
			term.write(`\x1b[2m${banner}\x1b[0m`);

			// Defer the first fit so flexbox has finished laying out. Decouple
			// fit() and observeResize() so an early fit failure doesn't prevent
			// observeResize from catching later layout changes.
			requestAnimationFrame(() => {
				if (state.disposed) return;
				try {
					fitAddon.fit();
				} catch {
					// container not sized yet
				}
				try {
					fitAddon.observeResize();
				} catch {
					// best-effort
				}
			});
		}

		setup();

		return () => {
			cancelled = true;
			const state = stateRef.current;
			if (state) {
				state.disposed = true;
				if (state.reconnectTimer !== null) {
					clearTimeout(state.reconnectTimer);
				}
				state.ws?.close();
				state.term.dispose();
			}
			stateRef.current = null;
		};
		// Mount per agent — sandbox restarts won't recreate the term.
	}, [agentName]);

	// WebSocket effect — connects when terminalUrl is set or changes.
	// On reconnect (e.g. after Resume), we close the old socket and open
	// a new one against the new URL while keeping the term alive.
	useEffect(() => {
		const state = stateRef.current;
		if (!state) {
			// State isn't ready yet — the mount effect runs async (await init()).
			// Re-run this effect when state becomes available by depending on
			// a sentinel ref. Simplest: schedule a microtask retry.
			const id = setTimeout(() => connectIfReady(), 100);
			return () => clearTimeout(id);
		}
		connectIfReady();

		function connectIfReady() {
			const s = stateRef.current;
			if (!s || s.disposed) return;
			if (s.currentUrl === terminalUrl && s.ws?.readyState === WebSocket.OPEN) {
				return; // already on the right URL
			}
			// Tear down any pending reconnect timer and existing WS
			if (s.reconnectTimer !== null) {
				clearTimeout(s.reconnectTimer);
				s.reconnectTimer = null;
			}
			if (s.ws) {
				const old = s.ws;
				s.ws = null;
				try {
					old.close();
				} catch {
					// ignore
				}
			}
			s.currentUrl = terminalUrl;
			openWebSocket(s, terminalUrl);
		}

		function openWebSocket(s: MountedState, url: string) {
			if (s.disposed) return;
			const ws = new WebSocket(url, ["tty"]);
			ws.binaryType = "arraybuffer";
			s.ws = ws;

			const decoder = new TextDecoder();

			ws.onopen = () => {
				if (s.disposed) {
					ws.close();
					return;
				}
				ws.send(
					JSON.stringify({
						AuthToken: "",
						columns: s.term.cols,
						rows: s.term.rows,
					}),
				);
				s.term.write("Connected to sandbox shell\r\n\r\n");
			};

			ws.onmessage = (event) => {
				if (!(event.data instanceof ArrayBuffer)) return;
				const data = new Uint8Array(event.data);
				if (data.length === 0) return;
				const cmd = String.fromCharCode(data[0]);
				if (cmd === "0") {
					s.term.write(decoder.decode(data.slice(1)));
				}
			};

			ws.onerror = () => {
				if (!s.disposed) {
					s.term.write("\x1b[31mWebSocket error\x1b[0m\r\n");
				}
			};

			ws.onclose = () => {
				if (s.ws === ws) s.ws = null;
				if (s.disposed) return;
				// Only auto-reconnect if the URL hasn't changed; if it has, the
				// WebSocket effect will run again with the new URL on its own.
				if (s.currentUrl !== url) return;
				s.term.write(
					"\r\n\x1b[33mDisconnected. Reconnecting in 2s...\x1b[0m\r\n",
				);
				s.reconnectTimer = window.setTimeout(() => {
					s.reconnectTimer = null;
					if (!s.disposed && s.currentUrl === url) {
						openWebSocket(s, url);
					}
				}, 2000);
			};
		}
	}, [terminalUrl]);

	// When the canvas becomes active, refit. The container's dimensions
	// might have changed while it was display:none.
	useEffect(() => {
		if (!active) return;
		const state = stateRef.current;
		if (!state) return;
		requestAnimationFrame(() => {
			try {
				state.fitAddon.fit();
			} catch {
				// best-effort
			}
		});
	}, [active]);

	return (
		<div
			ref={containerRef}
			className={styles.terminalInstance}
			style={{ display: active ? "block" : "none" }}
		/>
	);
}
