import type { AgentDiscoveryResponse } from "@/lib/types";
import { AgentCard } from "./agent-card";
import styles from "./main-panel.module.css";
import { PipelineBoard } from "./pipeline";

interface MainPanelProps {
	agentData: AgentDiscoveryResponse | null;
	selectedRepo: { owner: string; repo: string } | null;
	loading: boolean;
}

export function MainPanel({
	agentData,
	selectedRepo,
	loading,
}: MainPanelProps) {
	if (!selectedRepo) {
		return (
			<div className={styles.panel}>
				<div className={styles.empty}>
					<h2 className={styles.greeting}>
						Select a repo to view agent activity
					</h2>
					<span className={styles.emptyHint}>
						Choose a repository from the sidebar to discover agents, skills, and
						pipeline status
					</span>
				</div>
			</div>
		);
	}

	if (loading) {
		return (
			<div className={styles.panel}>
				<div className={styles.skeletonHeader} />
				<div className={styles.grid}>
					{Array.from({ length: 4 }).map((_, i) => (
						<div key={`s${_}`} className={styles.skeletonStat} />
					))}
				</div>
				<div className={styles.skeletonSection} />
				<div className={styles.agentGrid}>
					{Array.from({ length: 2 }).map((_, i) => (
						<div key={`c${_}`} className={styles.skeletonCard} />
					))}
				</div>
			</div>
		);
	}

	if (agentData && agentData.agents.length === 0) {
		return (
			<div className={styles.panel}>
				<h2 className={styles.repoTitle}>
					{selectedRepo.owner}/{selectedRepo.repo}
				</h2>
				<div className={styles.noAgents}>
					<span className={styles.noAgentsIcon}>&gt;_</span>
					<span className={styles.noAgentsTitle}>No agent setup detected</span>
					<span className={styles.noAgentsHint}>
						Add a <code className={styles.code}>.agents/</code> directory to
						this repo to get started
					</span>
				</div>
			</div>
		);
	}

	if (!agentData) return null;

	const { stats, agents, pipeline } = agentData;

	return (
		<div className={styles.panel}>
			<h2 className={styles.repoTitle}>
				{selectedRepo.owner}/{selectedRepo.repo}
			</h2>

			<div className={styles.grid}>
				<StatCard label="Agents" value={stats.agentCount} accent />
				<StatCard label="Skills" value={stats.skillCount} />
				<StatCard label="Open PRs" value={stats.openPRs} />
				<StatCard label="Ready Issues" value={stats.readyIssues} />
			</div>

			<div className={styles.section}>
				<span className={styles.sectionLabel}>Agent Team</span>
			</div>

			<div className={styles.agentGrid}>
				{agents.map((agent) => (
					<AgentCard key={agent.name} agent={agent} />
				))}
			</div>

			<div className={styles.section}>
				<span className={styles.sectionLabel}>Issue Pipeline</span>
			</div>

			<PipelineBoard pipeline={pipeline} />
		</div>
	);
}

function StatCard({
	label,
	value,
	accent,
}: { label: string; value: number; accent?: boolean }) {
	return (
		<div className={styles.stat}>
			<span
				className={`${styles.statValue} ${accent ? styles.statAccent : ""}`}
			>
				{value}
			</span>
			<span className={styles.statLabel}>{label}</span>
		</div>
	);
}
