"use client";

import styles from "./agent-sub-tabs.module.css";

export type AgentSessionState = "running" | "paused";

export interface AgentTab {
	agentName: string;
	state?: AgentSessionState;
	/** Optional display label. Falls back to agentName. */
	label?: string;
}

interface AgentSubTabsProps {
	tabs: AgentTab[];
	selected: string | null;
	onSelect: (agentName: string) => void;
}

/**
 * Horizontal agent sub-tab strip used by the Chat tab.
 * Shows a live/paused dot next to each agent name. The selected tab is
 * persisted via URL param (`?agent=<name>`) at the dashboard-shell level,
 * so switching main tabs preserves the agent context.
 */
export function AgentSubTabs({ tabs, selected, onSelect }: AgentSubTabsProps) {
	if (tabs.length === 0) return null;

	return (
		<nav className={styles.subTabBar}>
			{tabs.map((tab) => {
				const isActive = tab.agentName === selected;
				const dotClass = [
					styles.dot,
					tab.state === "running" && styles.dotRunning,
					tab.state === "paused" && styles.dotPaused,
				]
					.filter(Boolean)
					.join(" ");
				return (
					<button
						type="button"
						key={tab.agentName}
						className={`${styles.subTab} ${isActive ? styles.subTabActive : ""}`}
						onClick={() => onSelect(tab.agentName)}
					>
						<span className={dotClass} />
						<span>{tab.label ?? tab.agentName}</span>
					</button>
				);
			})}
		</nav>
	);
}
