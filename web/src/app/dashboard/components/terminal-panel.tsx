"use client";

import type { Agent } from "@/lib/types";
import { useCallback, useEffect, useRef, useState } from "react";
import { AgentSubTabs } from "./agent-sub-tabs";
import styles from "./terminal-panel.module.css";

interface TerminalSessionInfo {
	agentName: string;
	state: "running" | "paused";
	sandboxId: string;
	provider: string;
	terminalUrl?: string;
}

interface StatusResponse {
	sessions: TerminalSessionInfo[];
}

interface TerminalPanelProps {
	selectedRepo: { owner: string; repo: string } | null;
	selectedAgent: string | null;
	onSelectAgent: (agentName: string | null) => void;
	availableAgents?: Agent[];
}

// ghostty-web types (loaded dynamically)
type GhosttyTerminal = import("ghostty-web").Terminal;
type GhosttyFitAddon = import("ghostty-web").FitAddon;

export function TerminalPanel({
	selectedRepo,
	selectedAgent,
	onSelectAgent,
}: TerminalPanelProps) {
	const repo = selectedRepo
		? `${selectedRepo.owner}/${selectedRepo.repo}`
		: null;

	const [sessions, setSessions] = useState<TerminalSessionInfo[]>([]);
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const termContainerRef = useRef<HTMLDivElement>(null);
	const terminalRef = useRef<GhosttyTerminal | null>(null);
	const fitAddonRef = useRef<GhosttyFitAddon | null>(null);
	const wsRef = useRef<WebSocket | null>(null);

	// Which session is currently being shown? Derived from selectedAgent + sessions
	const activeSession = sessions.find((s) => s.agentName === selectedAgent);

	// Poll status API
	const refreshSessions = useCallback(async () => {
		if (!repo) {
			setSessions([]);
			return;
		}
		try {
			const res = await fetch(
				`/api/terminal/status?repo=${encodeURIComponent(repo)}`,
			);
			if (res.ok) {
				const data: StatusResponse = await res.json();
				setSessions(data.sessions ?? []);
			}
		} catch {
			// silent — next poll will retry
		}
	}, [repo]);

	useEffect(() => {
		refreshSessions();
		const id = setInterval(refreshSessions, 10_000);
		return () => clearInterval(id);
	}, [refreshSessions]);

	// Auto-select first session if none selected
	useEffect(() => {
		if (selectedAgent) return;
		if (sessions.length === 0) return;
		onSelectAgent(sessions[0].agentName);
	}, [selectedAgent, sessions, onSelectAgent]);

	// Start a new terminal sandbox (uses DEFAULT_AGENT on the server)
	const startTerminal = useCallback(
		async (agentName?: string) => {
			if (!repo || busy) return;
			setBusy(true);
			setError(null);
			try {
				const res = await fetch("/api/terminal/start", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ repo, agentName }),
				});
				if (!res.ok) {
					const body = await res.json().catch(() => ({}));
					setError(body.error ?? `HTTP ${res.status}`);
					return;
				}
				const data = (await res.json()) as { agentName: string };
				onSelectAgent(data.agentName);
				for (let i = 0; i < 15; i++) {
					await new Promise((r) => setTimeout(r, 1000));
					await refreshSessions();
				}
			} catch (err) {
				setError(err instanceof Error ? err.message : "Start failed");
			} finally {
				setBusy(false);
			}
		},
		[repo, busy, refreshSessions, onSelectAgent],
	);

	// Resume a paused session by restoring its snapshot
	const resumeTerminal = useCallback(
		async (agentName: string) => {
			if (!repo || busy) return;
			setBusy(true);
			setError(null);
			try {
				const res = await fetch("/api/terminal/resume", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ repo, agentName }),
				});
				if (!res.ok) {
					const body = await res.json().catch(() => ({}));
					setError(body.error ?? `HTTP ${res.status}`);
					return;
				}
				for (let i = 0; i < 15; i++) {
					await new Promise((r) => setTimeout(r, 1000));
					await refreshSessions();
				}
			} catch (err) {
				setError(err instanceof Error ? err.message : "Resume failed");
			} finally {
				setBusy(false);
			}
		},
		[repo, busy, refreshSessions],
	);

	// Stop the currently-selected agent's sandbox
	const stopTerminal = useCallback(async () => {
		if (!repo || !selectedAgent) return;
		try {
			await fetch("/api/terminal/stop", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ repo, agentName: selectedAgent }),
			});
		} catch {
			// ignore
		}
		await refreshSessions();
	}, [repo, selectedAgent, refreshSessions]);

	// Initialize / reconnect ghostty-web for the active (running) session.
	// Re-runs whenever the selected agent's terminalUrl changes.
	const runningUrl =
		activeSession?.state === "running" ? activeSession.terminalUrl : null;

	useEffect(() => {
		if (!termContainerRef.current || !runningUrl) return;

		let disposed = false;

		async function setup() {
			const { init, Terminal, FitAddon } = await import("ghostty-web");
			await init();

			if (disposed) return;
			const container = termContainerRef.current;
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

			if (runningUrl) {
				connectWebSocket(term, runningUrl);
			}
		}

		/**
		 * ttyd WebSocket protocol:
		 * - Subprotocol: `tty`
		 * - Binary frames only
		 * - On open: send JSON `{AuthToken, columns, rows}` as text
		 * - Command byte prefix: '0'=INPUT/OUTPUT, '1'=RESIZE/TITLE, '2'=PREFS
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
				frame[0] = "0".charCodeAt(0);
				frame.set(payload, 1);
				ws.send(frame);
			};

			const sendResize = (cols: number, rows: number) => {
				if (ws.readyState !== WebSocket.OPEN) return;
				const payload = encoder.encode(JSON.stringify({ columns: cols, rows }));
				const frame = new Uint8Array(payload.length + 1);
				frame[0] = "1".charCodeAt(0);
				frame.set(payload, 1);
				ws.send(frame);
			};

			ws.onopen = () => {
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
				if (cmd === "0") {
					term.write(decoder.decode(data.slice(1)));
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
						if (!disposed && runningUrl) connectWebSocket(term, runningUrl);
					}, 2000);
				}
			};

			term.onData(sendInput);
			term.onResize(({ cols, rows }) => sendResize(cols, rows));
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
	}, [runningUrl]);

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

	const subTabs = sessions.map((s) => ({
		agentName: s.agentName,
		state: s.state,
	}));

	// Empty state — no sessions at all
	if (sessions.length === 0) {
		return (
			<>
				<AgentSubTabs
					tabs={[]}
					selected={null}
					onSelect={() => {}}
					onNew={() => startTerminal()}
				/>
				<div className={styles.noSession}>
					<span className={styles.noSessionIcon}>&gt;_</span>
					<span className={styles.noSessionText}>
						No active terminal. Start a fresh shell with the repo cloned and
						ready.
					</span>
					<button
						type="button"
						className={styles.startButton}
						onClick={() => startTerminal()}
						disabled={busy}
					>
						{busy ? "Starting sandbox..." : "Start terminal"}
					</button>
					{error && <span className={styles.startError}>{error}</span>}
				</div>
			</>
		);
	}

	// Paused state — session exists but sandbox is snapshotted, needs resume
	if (activeSession?.state === "paused") {
		return (
			<>
				<AgentSubTabs
					tabs={subTabs}
					selected={selectedAgent}
					onSelect={onSelectAgent}
					onNew={() => startTerminal()}
				/>
				<div className={styles.noSession}>
					<span className={styles.noSessionIcon}>⏸</span>
					<span className={styles.noSessionText}>
						<strong>{activeSession.agentName}</strong>&apos;s sandbox is paused.
						Resume it to reconnect the terminal.
					</span>
					<button
						type="button"
						className={styles.startButton}
						onClick={() => resumeTerminal(activeSession.agentName)}
						disabled={busy}
					>
						{busy ? "Resuming..." : "Resume"}
					</button>
					{error && <span className={styles.startError}>{error}</span>}
				</div>
			</>
		);
	}

	// Running state — render the terminal
	return (
		<>
			<AgentSubTabs
				tabs={subTabs}
				selected={selectedAgent}
				onSelect={onSelectAgent}
				onNew={() => startTerminal()}
			/>
			<div className={styles.panel}>
				<div
					key={activeSession?.sandboxId ?? "none"}
					ref={termContainerRef}
					className={styles.terminal}
				/>
				<div className={styles.statusBar}>
					<span
						className={`${styles.statusDot} ${styles.statusDotConnected}`}
					/>
					<span className={styles.statusText}>
						PTY: {activeSession?.agentName ?? "sandbox"}
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
		</>
	);
}
