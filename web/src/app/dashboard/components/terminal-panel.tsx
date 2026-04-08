"use client";

import type { Agent } from "@/lib/types";
import { useEffect } from "react";
import { AgentSubTabs } from "./agent-sub-tabs";
import { TerminalCanvas } from "./terminal-canvas";
import styles from "./terminal-panel.module.css";
import { useTerminalSessions } from "./use-terminal-sessions";

interface TerminalPanelProps {
	selectedRepo: { owner: string; repo: string } | null;
	selectedAgent: string | null;
	onSelectAgent: (agentName: string | null) => void;
	availableAgents?: Agent[];
}

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

	const {
		sessions,
		provisioning,
		error,
		startTerminal,
		stopTerminal,
		resumeTerminal,
	} = useTerminalSessions(repo);

	const activeSession = sessions.find((s) => s.agentName === selectedAgent);

	// Auto-select the first session when nothing is selected, or when the
	// currently-selected agent has neither a session nor is being provisioned.
	useEffect(() => {
		if (sessions.length === 0) return;
		if (!selectedAgent) {
			onSelectAgent(sessions[0].agentName);
			return;
		}
		const stillAround =
			sessions.some((s) => s.agentName === selectedAgent) ||
			provisioning[selectedAgent];
		if (!stillAround) {
			onSelectAgent(sessions[0].agentName);
		}
	}, [selectedAgent, sessions, provisioning, onSelectAgent]);

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

	// Build the sub-tab list: sessions + any provisioning slots not yet
	// in sessions (so the placeholder shows up immediately on click).
	const subTabs: Array<{
		agentName: string;
		state?: "running" | "paused";
		label: string;
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
			});
		}
	}

	const provisioningHere =
		(selectedAgent && provisioning[selectedAgent]) || null;
	const isProvisioning = !!(
		activeSession && provisioning[activeSession.agentName]
	);

	// Empty state — no sessions, no provisioning
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

	// Provisioning placeholder — sub-tab is in the strip but no session yet
	if (provisioningHere && !activeSession) {
		return (
			<>
				<AgentSubTabs
					tabs={subTabs}
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
					tabs={subTabs}
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

	// Selected agent has no session in the sessions list (and not provisioning).
	// Show a targeted "start one for this agent" prompt instead of falling
	// through to a wonky empty terminal canvas.
	if (selectedAgent && !activeSession) {
		return (
			<>
				<AgentSubTabs
					tabs={subTabs}
					selected={selectedAgent}
					onSelect={onSelectAgent}
					onNew={() => startTerminal()}
				/>
				<div className={styles.noSession}>
					<span className={styles.noSessionIcon}>&gt;_</span>
					<span className={styles.noSessionText}>
						No active terminal for{" "}
						<strong>{displayAgentName(selectedAgent)}</strong>. Start a fresh
						shell with the repo cloned and ready.
					</span>
					<button
						type="button"
						className={styles.startButton}
						onClick={() => startTerminal(selectedAgent)}
					>
						Start terminal for {displayAgentName(selectedAgent)}
					</button>
					{error && <span className={styles.startError}>{error}</span>}
				</div>
			</>
		);
	}

	// Running state — render one TerminalCanvas per running session and
	// hide non-active ones with display:none. The canvases stay alive in
	// the DOM so scrollback persists across sub-tab switches.
	const runningSessions = sessions.filter(
		(s) => s.state === "running" && s.terminalUrl,
	);

	return (
		<>
			<AgentSubTabs
				tabs={subTabs}
				selected={selectedAgent}
				onSelect={onSelectAgent}
				onNew={() => startTerminal()}
			/>
			<div className={styles.panel}>
				<div className={styles.terminalHost}>
					{runningSessions.map((s) => (
						<TerminalCanvas
							key={s.agentName}
							agentName={s.agentName}
							terminalUrl={s.terminalUrl as string}
							active={s.agentName === selectedAgent}
						/>
					))}
				</div>
				<div className={styles.statusBar}>
					<span
						className={`${styles.statusDot} ${styles.statusDotConnected}`}
					/>
					<span className={styles.statusText}>
						PTY: {displayAgentName(activeSession?.agentName ?? SHELL_SLOT)}
					</span>
					<button
						type="button"
						className={styles.stopButton}
						onClick={() =>
							activeSession && stopTerminal(activeSession.agentName)
						}
						title={`Stop ${displayAgentName(activeSession?.agentName ?? SHELL_SLOT)}`}
					>
						Stop {displayAgentName(activeSession?.agentName ?? SHELL_SLOT)}
					</button>
				</div>
			</div>
		</>
	);
}
