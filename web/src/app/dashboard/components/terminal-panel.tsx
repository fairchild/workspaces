"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import styles from "./terminal-panel.module.css";

type ConnectionState = "disconnected" | "connecting" | "connected";

interface SandboxStatus {
	connected: boolean;
	sandboxId?: string;
	agentName?: string;
	/** WebSocket URL for direct PTY connection (TerminalShare or sandbox port) */
	terminalUrl?: string;
}

interface TerminalPanelProps {
	selectedRepo: { owner: string; repo: string } | null;
}

// ghostty-web types (loaded dynamically)
type GhosttyTerminal = import("ghostty-web").Terminal;
type GhosttyFitAddon = import("ghostty-web").FitAddon;

export function TerminalPanel({ selectedRepo }: TerminalPanelProps) {
	const repo = selectedRepo
		? `${selectedRepo.owner}/${selectedRepo.repo}`
		: null;

	const [connectionState, setConnectionState] =
		useState<ConnectionState>("disconnected");
	const [sandboxInfo, setSandboxInfo] = useState<SandboxStatus | null>(null);
	const [starting, setStarting] = useState(false);
	const [startError, setStartError] = useState<string | null>(null);
	const termRef = useRef<HTMLDivElement>(null);
	const terminalRef = useRef<GhosttyTerminal | null>(null);
	const fitAddonRef = useRef<GhosttyFitAddon | null>(null);
	const wsRef = useRef<WebSocket | null>(null);
	const inputBufferRef = useRef("");
	const abortRef = useRef<AbortController | null>(null);
	const cwdRef = useRef("/vercel/sandbox/repo");

	// Check for active sandbox
	const checkStatus = useCallback(async () => {
		if (!repo) {
			setSandboxInfo(null);
			setConnectionState("disconnected");
			return;
		}

		try {
			const res = await fetch(
				`/api/terminal/status?repo=${encodeURIComponent(repo)}`,
			);
			if (res.ok) {
				const data: SandboxStatus = await res.json();
				setSandboxInfo(data);
				setConnectionState(data.connected ? "connected" : "disconnected");
			}
		} catch {
			setSandboxInfo(null);
			setConnectionState("disconnected");
		}
	}, [repo]);

	// Poll for sandbox status
	useEffect(() => {
		checkStatus();
		const id = setInterval(checkStatus, 10_000);
		return () => clearInterval(id);
	}, [checkStatus]);

	// Start a standalone terminal sandbox
	const startTerminal = useCallback(async () => {
		if (!repo || starting) return;
		setStarting(true);
		setStartError(null);
		try {
			const res = await fetch("/api/terminal/start", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ repo }),
			});
			if (!res.ok) {
				const body = await res.json().catch(() => ({}));
				setStartError(body.error ?? `HTTP ${res.status}`);
				return;
			}
			// Poll status until we see the connected state
			for (let i = 0; i < 10; i++) {
				await new Promise((r) => setTimeout(r, 1000));
				await checkStatus();
			}
		} catch (err) {
			setStartError(err instanceof Error ? err.message : "Start failed");
		} finally {
			setStarting(false);
		}
	}, [repo, starting, checkStatus]);

	// Stop the active terminal sandbox
	const stopTerminal = useCallback(async () => {
		if (!repo) return;
		try {
			await fetch("/api/terminal/stop", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ repo }),
			});
		} catch {
			// Best-effort; always re-check status afterward
		}
		await checkStatus();
	}, [repo, checkStatus]);

	// SSE fallback: execute a command via /api/terminal/exec
	const execCommand = useCallback(
		async (command: string) => {
			if (!repo || connectionState !== "connected") return;

			abortRef.current?.abort();
			const controller = new AbortController();
			abortRef.current = controller;

			const term = terminalRef.current;
			if (!term) return;

			const cdMatch = command.match(/^\s*cd\s+(.*)/);
			const wrappedCommand = cdMatch
				? `cd ${cwdRef.current} && cd ${cdMatch[1]} && pwd`
				: `cd ${cwdRef.current} && ${command}`;

			try {
				const res = await fetch("/api/terminal/exec", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ repo, command: wrappedCommand }),
					signal: controller.signal,
				});

				if (!res.ok || !res.body) {
					term.write(
						`\x1b[31mError: ${res.statusText || "Command failed"}\x1b[0m\r\n`,
					);
					return;
				}

				const reader = res.body.getReader();
				const decoder = new TextDecoder();
				let buffer = "";
				let lastOutput = "";

				while (true) {
					const { done, value } = await reader.read();
					if (done) break;

					buffer += decoder.decode(value, { stream: true });
					const lines = buffer.split("\n");
					buffer = lines.pop() ?? "";

					for (const line of lines) {
						if (!line.startsWith("data: ")) continue;
						try {
							const chunk = JSON.parse(line.slice(6));
							if (chunk.stream === "stdout" || chunk.stream === "stderr") {
								const text = chunk.data.replace(/\n/g, "\r\n");
								term.write(text);
								lastOutput = chunk.data;
							} else if (chunk.type === "exit") {
								if (cdMatch && chunk.exitCode === 0 && lastOutput.trim()) {
									cwdRef.current =
										lastOutput.trim().split("\n").pop() ?? cwdRef.current;
								}
							} else if (chunk.type === "error") {
								term.write(`\x1b[31m${chunk.data}\x1b[0m\r\n`);
							}
						} catch {
							// skip malformed SSE
						}
					}
				}
			} catch (err) {
				if (err instanceof DOMException && err.name === "AbortError") return;
				term.write("\x1b[31mConnection lost\x1b[0m\r\n");
			} finally {
				abortRef.current = null;
			}
		},
		[repo, connectionState],
	);

	const writePrompt = useCallback(() => {
		const term = terminalRef.current;
		if (!term) return;
		const shortCwd = cwdRef.current.replace("/vercel/sandbox/repo", "~");
		term.write(`\x1b[32m${shortCwd}\x1b[0m $ `);
	}, []);

	// Initialize terminal
	useEffect(() => {
		if (!termRef.current || connectionState !== "connected") return;

		let disposed = false;

		async function setup() {
			const { init, Terminal, FitAddon } = await import("ghostty-web");
			await init();

			if (disposed) return;
			const container = termRef.current;
			if (!container) return;

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

			term.loadAddon(fitAddon);
			term.open(container);
			fitAddon.fit();

			terminalRef.current = term;
			fitAddonRef.current = fitAddon;

			// WebSocket mode: direct PTY connection
			if (sandboxInfo?.terminalUrl) {
				connectWebSocket(term, sandboxInfo.terminalUrl);
			} else {
				// SSE fallback: line-based command execution
				setupLineInput(term);
			}
		}

		/**
		 * ttyd WebSocket protocol:
		 * - Subprotocol: `tty`
		 * - Binary frames only
		 * - On open: send JSON `{AuthToken, columns, rows}` as text (not framed)
		 * - Server → client: first byte is the command
		 *     '0' OUTPUT, '1' SET_WINDOW_TITLE, '2' SET_PREFERENCES
		 * - Client → server: first byte is the command
		 *     '0' INPUT (data), '1' RESIZE_TERMINAL (JSON)
		 */
		function connectWebSocket(term: GhosttyTerminal, url: string) {
			const ws = new WebSocket(url, ["tty"]);
			ws.binaryType = "arraybuffer";
			wsRef.current = ws;

			const encoder = new TextEncoder();
			const decoder = new TextDecoder();

			const sendInput = (data: string) => {
				if (ws.readyState !== WebSocket.OPEN) return;
				const payload = encoder.encode(data);
				const frame = new Uint8Array(payload.length + 1);
				frame[0] = "0".charCodeAt(0); // INPUT
				frame.set(payload, 1);
				ws.send(frame);
			};

			const sendResize = (cols: number, rows: number) => {
				if (ws.readyState !== WebSocket.OPEN) return;
				const payload = encoder.encode(JSON.stringify({ columns: cols, rows }));
				const frame = new Uint8Array(payload.length + 1);
				frame[0] = "1".charCodeAt(0); // RESIZE_TERMINAL
				frame.set(payload, 1);
				ws.send(frame);
			};

			ws.onopen = () => {
				// ttyd auth handshake — empty token is fine (no auth configured)
				ws.send(
					JSON.stringify({
						AuthToken: "",
						columns: term.cols,
						rows: term.rows,
					}),
				);
				term.write("Connected to sandbox shell\r\n\r\n");
			};

			ws.onmessage = (event) => {
				if (!(event.data instanceof ArrayBuffer)) return;
				const data = new Uint8Array(event.data);
				if (data.length === 0) return;
				const cmd = String.fromCharCode(data[0]);
				const rest = data.slice(1);
				if (cmd === "0") {
					// OUTPUT
					term.write(decoder.decode(rest));
				} else if (cmd === "1") {
					// SET_WINDOW_TITLE — ignore
				} else if (cmd === "2") {
					// SET_PREFERENCES — ignore
				}
			};

			ws.onerror = () => {
				term.write("\x1b[31mWebSocket error\x1b[0m\r\n");
			};

			ws.onclose = () => {
				wsRef.current = null;
				if (!disposed) {
					term.write(
						"\r\n\x1b[33mDisconnected. Reconnecting in 2s...\x1b[0m\r\n",
					);
					setTimeout(() => {
						if (!disposed && sandboxInfo?.terminalUrl) {
							connectWebSocket(term, sandboxInfo.terminalUrl);
						}
					}, 2000);
				}
			};

			// Keystrokes → ttyd INPUT frame
			term.onData(sendInput);

			// Resize → ttyd RESIZE_TERMINAL frame
			term.onResize(({ cols, rows }) => sendResize(cols, rows));
		}

		function setupLineInput(term: GhosttyTerminal) {
			term.write("Connected to sandbox shell\r\n\r\n");
			writePrompt();

			term.onData((data) => {
				if (data === "\r") {
					term.write("\r\n");
					const cmd = inputBufferRef.current.trim();
					inputBufferRef.current = "";
					if (cmd) {
						execCommand(cmd).then(() => writePrompt());
					} else {
						writePrompt();
					}
				} else if (data === "\u007f") {
					if (inputBufferRef.current.length > 0) {
						inputBufferRef.current = inputBufferRef.current.slice(0, -1);
						term.write("\b \b");
					}
				} else if (data === "\u0003") {
					inputBufferRef.current = "";
					term.write("^C\r\n");
					abortRef.current?.abort();
					writePrompt();
				} else if (data >= " ") {
					inputBufferRef.current += data;
					term.write(data);
				}
			});
		}

		setup();

		const handleResize = () => fitAddonRef.current?.fit();
		window.addEventListener("resize", handleResize);

		return () => {
			disposed = true;
			window.removeEventListener("resize", handleResize);
			wsRef.current?.close();
			wsRef.current = null;
			terminalRef.current?.dispose();
			terminalRef.current = null;
			fitAddonRef.current = null;
		};
	}, [connectionState, sandboxInfo?.terminalUrl, execCommand, writePrompt]);

	// Fit terminal when it becomes visible (tab switch)
	useEffect(() => {
		const timer = setTimeout(() => fitAddonRef.current?.fit(), 50);
		return () => clearTimeout(timer);
	});

	if (!selectedRepo) {
		return (
			<div className={styles.noSession}>
				<span className={styles.noSessionIcon}>&gt;_</span>
				<span className={styles.noSessionText}>
					Select a repository from the sidebar to access its terminal.
				</span>
			</div>
		);
	}

	if (connectionState === "disconnected" || !sandboxInfo?.connected) {
		return (
			<div className={styles.noSession}>
				<span className={styles.noSessionIcon}>&gt;_</span>
				<span className={styles.noSessionText}>
					No active terminal. Start a fresh shell with the repo cloned and
					ready.
				</span>
				<button
					type="button"
					className={styles.startButton}
					onClick={startTerminal}
					disabled={starting}
				>
					{starting ? "Starting sandbox..." : "Start terminal"}
				</button>
				{startError && <span className={styles.startError}>{startError}</span>}
			</div>
		);
	}

	return (
		<div className={styles.panel}>
			<div ref={termRef} className={styles.terminal} />
			<div className={styles.statusBar}>
				<span
					className={`${styles.statusDot} ${connectionState === "connected" ? styles.statusDotConnected : ""}`}
				/>
				<span className={styles.statusText}>
					{connectionState === "connecting"
						? "Connecting..."
						: sandboxInfo?.terminalUrl
							? `PTY: ${sandboxInfo?.agentName ?? "sandbox"}`
							: `Shell: ${sandboxInfo?.agentName ?? "sandbox"}`}
				</span>
				<button
					type="button"
					className={styles.stopButton}
					onClick={stopTerminal}
				>
					Stop
				</button>
			</div>
		</div>
	);
}
