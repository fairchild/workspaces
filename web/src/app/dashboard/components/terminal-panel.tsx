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

interface MountedTerminal {
	term: GhosttyTerminal;
	fitAddon: GhosttyFitAddon;
	ws: WebSocket | null;
	disposed: boolean;
}

/**
 * The synthetic agent slot used when no agent is specified. We label it
 * "shell" in the UI but the backend column is "shell".
 */
const SHELL_SLOT = "shell";

/** Pretty label for the synthetic shell slot. */
function displayAgentName(name: string): string {
	if (name === SHELL_SLOT || name === "terminal") return "shell";
	return name;
}

export function TerminalPanel({
	selectedRepo,
	selectedAgent,
	onSelectAgent,
}: TerminalPanelProps) {
	const repo = selectedRepo
		? `${selectedRepo.owner}/${selectedRepo.repo}`
		: null;

	const [sessions, setSessions] = useState<TerminalSessionInfo[]>([]);
	// Provisioning state: { agentName: "starting" | "resuming" }
	const [provisioning, setProvisioning] = useState<
		Record<string, "starting" | "resuming">
	>({});
	const [error, setError] = useState<string | null>(null);

	// One mounted terminal per (sandboxId). React doesn't render these
	// directly — we create the divs ourselves and ghostty-web attaches.
	const mountedRef = useRef<Map<string, MountedTerminal>>(new Map());
	const containerHostRef = useRef<HTMLDivElement>(null);

	const activeSession = sessions.find((s) => s.agentName === selectedAgent);

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

	// Provision a new sandbox for an agent (or default shell slot)
	const startTerminal = useCallback(
		async (agentName?: string) => {
			if (!repo) return;
			const slot = agentName ?? SHELL_SLOT;
			if (provisioning[slot]) return;

			setProvisioning((p) => ({ ...p, [slot]: "starting" }));
			setError(null);
			onSelectAgent(slot);

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
				// Poll until the new session shows up in the list
				for (let i = 0; i < 20; i++) {
					await new Promise((r) => setTimeout(r, 1000));
					await refreshSessions();
				}
			} catch (err) {
				setError(err instanceof Error ? err.message : "Start failed");
			} finally {
				setProvisioning((p) => {
					const next = { ...p };
					delete next[slot];
					return next;
				});
			}
		},
		[repo, provisioning, refreshSessions, onSelectAgent],
	);

	// Restore a paused session's snapshot
	const resumeTerminal = useCallback(
		async (agentName: string) => {
			if (!repo || provisioning[agentName]) return;
			setProvisioning((p) => ({ ...p, [agentName]: "resuming" }));
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
				for (let i = 0; i < 20; i++) {
					await new Promise((r) => setTimeout(r, 1000));
					await refreshSessions();
				}
			} catch (err) {
				setError(err instanceof Error ? err.message : "Resume failed");
			} finally {
				setProvisioning((p) => {
					const next = { ...p };
					delete next[agentName];
					return next;
				});
			}
		},
		[repo, provisioning, refreshSessions],
	);

	// Stop the currently-selected agent's sandbox
	const stopTerminal = useCallback(async () => {
		if (!repo || !activeSession) return;
		try {
			await fetch("/api/terminal/stop", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ repo, agentName: activeSession.agentName }),
			});
		} catch {
			// ignore
		}
		// Tear down the terminal locally so it doesn't linger
		const mounted = mountedRef.current.get(activeSession.sandboxId);
		if (mounted) {
			mounted.disposed = true;
			mounted.ws?.close();
			mounted.term.dispose();
			mountedRef.current.delete(activeSession.sandboxId);
		}
		await refreshSessions();
	}, [repo, activeSession, refreshSessions]);

	/**
	 * Mount/unmount terminals to match the running sessions list.
	 * - For every running session not yet mounted: create ghostty-web + ttyd WS
	 * - For every mounted terminal whose sandbox is gone: dispose
	 */
	useEffect(() => {
		const host = containerHostRef.current;
		if (!host) return;

		let cancelled = false;

		async function syncTerminals() {
			const { init, Terminal, FitAddon } = await import("ghostty-web");
			await init();
			if (cancelled || !host) return;

			const runningSessions = sessions.filter((s) => s.state === "running");
			const desired = new Set(runningSessions.map((s) => s.sandboxId));

			// Dispose terminals for sandboxes that are gone
			for (const [sandboxId, mounted] of mountedRef.current.entries()) {
				if (!desired.has(sandboxId)) {
					mounted.disposed = true;
					mounted.ws?.close();
					mounted.term.dispose();
					const div = host.querySelector(`[data-sandbox="${sandboxId}"]`);
					if (div) div.remove();
					mountedRef.current.delete(sandboxId);
				}
			}

			// Mount terminals for new sandboxes
			for (const session of runningSessions) {
				if (mountedRef.current.has(session.sandboxId)) continue;
				if (!session.terminalUrl) continue;

				const div = document.createElement("div");
				div.dataset.sandbox = session.sandboxId;
				div.className = styles.terminalInstance;
				host.appendChild(div);

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

				const mounted: MountedTerminal = {
					term,
					fitAddon,
					ws: null,
					disposed: false,
				};
				mountedRef.current.set(session.sandboxId, mounted);

				term.loadAddon(fitAddon);

				// Open the canvas, then defer the first fit to the next animation
				// frame so the layout has settled. Without this, ghostty-web measures
				// the canvas before flexbox has assigned heights and reports the
				// wrong cols/rows to ttyd.
				term.open(div);

				// Resize handler MUST be registered before fit so that the resize
				// event from the initial fit() reaches sendResize() and ttyd gets
				// the correct dimensions in its first frame.
				const sendResize = (cols: number, rows: number) => {
					if (mounted.ws?.readyState !== WebSocket.OPEN) return;
					const enc = new TextEncoder();
					const payload = enc.encode(JSON.stringify({ columns: cols, rows }));
					const frame = new Uint8Array(payload.length + 1);
					frame[0] = "1".charCodeAt(0);
					frame.set(payload, 1);
					mounted.ws.send(frame);
				};
				term.onResize(({ cols, rows }) => sendResize(cols, rows));

				// Defer to next animation frame so flexbox has finished laying out
				requestAnimationFrame(() => {
					if (mounted.disposed) return;
					try {
						fitAddon.fit();
						fitAddon.observeResize();
					} catch {
						// container not yet sized — try once more
						requestAnimationFrame(() => {
							if (!mounted.disposed) {
								try {
									fitAddon.fit();
									fitAddon.observeResize();
								} catch {
									// give up — terminal will use defaults
								}
							}
						});
					}
				});

				connectWebSocket(mounted, session.terminalUrl);
			}
		}

		function connectWebSocket(mounted: MountedTerminal, url: string) {
			const ws = new WebSocket(url, ["tty"]);
			ws.binaryType = "arraybuffer";
			mounted.ws = ws;

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

			ws.onopen = () => {
				// Send the actual terminal dimensions in the auth handshake. By
				// the time onopen fires, the deferred fit() has usually completed.
				ws.send(
					JSON.stringify({
						AuthToken: "",
						columns: mounted.term.cols,
						rows: mounted.term.rows,
					}),
				);
				mounted.term.write("Connected to sandbox shell\r\n\r\n");
				// Force-send a resize after handshake to be 100% sure ttyd has
				// the right dimensions even if onResize already fired before WS open.
				const enc = new TextEncoder();
				const payload = enc.encode(
					JSON.stringify({
						columns: mounted.term.cols,
						rows: mounted.term.rows,
					}),
				);
				const frame = new Uint8Array(payload.length + 1);
				frame[0] = "1".charCodeAt(0);
				frame.set(payload, 1);
				ws.send(frame);
			};

			ws.onmessage = (event) => {
				if (!(event.data instanceof ArrayBuffer)) return;
				const data = new Uint8Array(event.data);
				if (data.length === 0) return;
				const cmd = String.fromCharCode(data[0]);
				if (cmd === "0") {
					mounted.term.write(decoder.decode(data.slice(1)));
				}
			};

			ws.onerror = () => {
				mounted.term.write("\x1b[31mWebSocket error\x1b[0m\r\n");
			};

			ws.onclose = () => {
				mounted.ws = null;
				if (!mounted.disposed) {
					mounted.term.write(
						"\r\n\x1b[33mDisconnected. Reconnecting in 2s...\x1b[0m\r\n",
					);
					setTimeout(() => {
						if (!mounted.disposed) connectWebSocket(mounted, url);
					}, 2000);
				}
			};

			mounted.term.onData(sendInput);
		}

		syncTerminals();

		return () => {
			cancelled = true;
		};
	}, [sessions]);

	// Show/hide mounted terminals based on selectedAgent
	useEffect(() => {
		const host = containerHostRef.current;
		if (!host) return;
		const activeId = activeSession?.sandboxId;
		for (const child of Array.from(host.children) as HTMLDivElement[]) {
			const isActive = child.dataset.sandbox === activeId;
			child.style.display = isActive ? "block" : "none";
		}
		// Refit the now-visible terminal in case its container changed size
		if (activeId) {
			const mounted = mountedRef.current.get(activeId);
			if (mounted) {
				requestAnimationFrame(() => {
					try {
						mounted.fitAddon.fit();
					} catch {
						// ignore
					}
				});
			}
		}
	}, [activeSession?.sandboxId]);

	// Cleanup on unmount
	useEffect(() => {
		return () => {
			for (const mounted of mountedRef.current.values()) {
				mounted.disposed = true;
				mounted.ws?.close();
				mounted.term.dispose();
			}
			mountedRef.current.clear();
		};
	}, []);

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

	// Build sub-tab list: sessions + any provisioning slots not yet in sessions
	const subTabs: Array<{
		agentName: string;
		state?: "running" | "paused";
		label: string;
		busy?: boolean;
	}> = sessions.map((s) => ({
		agentName: s.agentName,
		state: s.state,
		label: displayAgentName(s.agentName),
	}));
	for (const slot of Object.keys(provisioning)) {
		if (!subTabs.some((t) => t.agentName === slot)) {
			subTabs.push({
				agentName: slot,
				label: displayAgentName(slot),
				busy: true,
			});
		}
	}

	const isProvisioning = !!(
		activeSession && provisioning[activeSession.agentName]
	);
	const provisioningHere = selectedAgent && provisioning[selectedAgent];

	// No sessions and not provisioning anything
	if (sessions.length === 0 && Object.keys(provisioning).length === 0) {
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
					>
						Start terminal
					</button>
					{error && <span className={styles.startError}>{error}</span>}
				</div>
			</>
		);
	}

	const subTabsForRender = subTabs.map((t) => ({
		agentName: t.agentName,
		state: t.busy ? undefined : t.state,
		label: t.label,
	}));

	// Provisioning placeholder for the selected slot
	if (provisioningHere && !activeSession) {
		return (
			<>
				<AgentSubTabs
					tabs={subTabsForRender}
					selected={selectedAgent}
					onSelect={onSelectAgent}
					onNew={() => startTerminal()}
				/>
				<div className={styles.noSession}>
					<span className={styles.spinner}>◐</span>
					<span className={styles.noSessionText}>
						{provisioningHere === "starting"
							? "Provisioning sandbox… (cloning repo, starting shell)"
							: "Restoring snapshot…"}
					</span>
				</div>
			</>
		);
	}

	// Paused state for the selected agent
	if (activeSession?.state === "paused") {
		return (
			<>
				<AgentSubTabs
					tabs={subTabsForRender}
					selected={selectedAgent}
					onSelect={onSelectAgent}
					onNew={() => startTerminal()}
				/>
				<div className={styles.noSession}>
					<span className={styles.noSessionIcon}>⏸</span>
					<span className={styles.noSessionText}>
						<strong>{displayAgentName(activeSession.agentName)}</strong>
						&apos;s sandbox is paused. Resume it to reconnect the terminal.
					</span>
					<button
						type="button"
						className={styles.startButton}
						onClick={() => resumeTerminal(activeSession.agentName)}
						disabled={isProvisioning}
					>
						{isProvisioning ? "Resuming…" : "Resume"}
					</button>
					{error && <span className={styles.startError}>{error}</span>}
				</div>
			</>
		);
	}

	// Running state — render the terminal hosts. The hosts are always
	// in the DOM (created by the syncTerminals effect); we just toggle
	// visibility via display:none above.
	return (
		<>
			<AgentSubTabs
				tabs={subTabsForRender}
				selected={selectedAgent}
				onSelect={onSelectAgent}
				onNew={() => startTerminal()}
			/>
			<div className={styles.panel}>
				<div ref={containerHostRef} className={styles.terminalHost} />
				<div className={styles.statusBar}>
					<span
						className={`${styles.statusDot} ${styles.statusDotConnected}`}
					/>
					<span className={styles.statusText}>
						PTY: {displayAgentName(activeSession?.agentName ?? "shell")}
					</span>
					<button
						type="button"
						className={styles.stopButton}
						onClick={stopTerminal}
						title={`Stop ${displayAgentName(activeSession?.agentName ?? "shell")}`}
					>
						Stop {displayAgentName(activeSession?.agentName ?? "shell")}
					</button>
				</div>
			</div>
		</>
	);
}
