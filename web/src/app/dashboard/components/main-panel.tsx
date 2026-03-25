import type { AgentDiscoveryResponse } from "@/lib/types";
import { useCallback, useEffect, useState } from "react";
import { AgentCard } from "./agent-card";
import styles from "./main-panel.module.css";
import { PipelineBoard } from "./pipeline";

const STORAGE_KEY = "spaces:collapsed-sections";

function getCollapsedSections(): Set<string> {
	if (typeof window === "undefined") return new Set();
	try {
		const stored = localStorage.getItem(STORAGE_KEY);
		return stored ? new Set(JSON.parse(stored)) : new Set();
	} catch {
		return new Set();
	}
}

function useCollapsible(section: string) {
	const [collapsed, setCollapsed] = useState(() =>
		getCollapsedSections().has(section),
	);

	const toggle = useCallback(() => {
		setCollapsed((prev) => {
			const next = !prev;
			try {
				const sections = getCollapsedSections();
				if (next) sections.add(section);
				else sections.delete(section);
				localStorage.setItem(STORAGE_KEY, JSON.stringify([...sections]));
			} catch {
				// localStorage unavailable
			}
			return next;
		});
	}, [section]);

	return { collapsed, toggle };
}

interface MainPanelProps {
	agentData: AgentDiscoveryResponse | null;
	selectedRepo: { owner: string; repo: string } | null;
	loading: boolean;
	error?: string | null;
}

export function MainPanel({
	agentData,
	selectedRepo,
	loading,
	error,
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
					{["s0", "s1", "s2", "s3"].map((id) => (
						<div key={id} className={styles.skeletonStat} />
					))}
				</div>
				<div className={styles.skeletonSection} />
				<div className={styles.agentGrid}>
					{["c0", "c1"].map((id) => (
						<div key={id} className={styles.skeletonCard} />
					))}
				</div>
			</div>
		);
	}

	if (error) {
		return (
			<div className={styles.panel}>
				<h2 className={styles.repoTitle}>
					{selectedRepo.owner}/{selectedRepo.repo}
				</h2>
				<div className={styles.noAgents}>
					<span className={styles.noAgentsIcon}>!</span>
					<span className={styles.noAgentsTitle}>{error}</span>
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
				<WebhookStatus owner={selectedRepo.owner} repo={selectedRepo.repo} />
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
	const statsSection = useCollapsible("stats");
	const agentsSection = useCollapsible("agents");
	const pipelineSection = useCollapsible("pipeline");

	return (
		<div className={styles.panel}>
			<h2 className={styles.repoTitle}>
				{selectedRepo.owner}/{selectedRepo.repo}
			</h2>
			<WebhookStatus owner={selectedRepo.owner} repo={selectedRepo.repo} />

			<SectionHeader
				label="Overview"
				collapsed={statsSection.collapsed}
				onToggle={statsSection.toggle}
			/>
			{!statsSection.collapsed && (
				<div className={styles.grid}>
					<StatCard label="Agents" value={stats.agentCount} accent />
					<StatCard label="Skills" value={stats.skillCount} />
					<StatCard label="Open PRs" value={stats.openPRs} />
					<StatCard label="Ready Issues" value={stats.readyIssues} />
				</div>
			)}

			<SectionHeader
				label="Agent Team"
				collapsed={agentsSection.collapsed}
				onToggle={agentsSection.toggle}
			/>
			{!agentsSection.collapsed && (
				<div className={styles.agentGrid}>
					{agents.map((agent) => (
						<AgentCard key={agent.name} agent={agent} />
					))}
				</div>
			)}

			<SectionHeader
				label="Issue Pipeline"
				collapsed={pipelineSection.collapsed}
				onToggle={pipelineSection.toggle}
			/>
			{!pipelineSection.collapsed && <PipelineBoard pipeline={pipeline} />}
		</div>
	);
}

function SectionHeader({
	label,
	collapsed,
	onToggle,
}: { label: string; collapsed: boolean; onToggle: () => void }) {
	return (
		<button type="button" className={styles.section} onClick={onToggle}>
			<span
				className={`${styles.sectionChevron} ${collapsed ? styles.sectionChevronCollapsed : ""}`}
			>
				&#9662;
			</span>
			<span className={styles.sectionLabel}>{label}</span>
		</button>
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

function formatTimeAgo(timestamp: string): string {
	const diff = Date.now() - new Date(timestamp).getTime();
	const mins = Math.floor(diff / 60000);
	if (mins < 1) return "just now";
	if (mins < 60) return `${mins}m ago`;
	const hours = Math.floor(mins / 60);
	if (hours < 24) return `${hours}h ago`;
	return `${Math.floor(hours / 24)}d ago`;
}

function WebhookStatus({ owner, repo }: { owner: string; repo: string }) {
	const [status, setStatus] = useState<{
		lastEvent: string | null;
		connected: boolean;
	} | null>(null);

	useEffect(() => {
		fetch(`/api/repos/${owner}/${repo}/webhook-status`)
			.then((r) => (r.ok ? r.json() : null))
			.then(setStatus)
			.catch(() => {});
	}, [owner, repo]);

	if (!status) return null;

	const appSettingsUrl = "https://github.com/settings/installations";

	return (
		<div className={styles.webhookStatus}>
			<span
				className={`${styles.webhookDot} ${status.connected ? styles.webhookConnected : styles.webhookDisconnected}`}
			/>
			<span className={styles.webhookText}>
				{status.connected && status.lastEvent
					? `Last event ${formatTimeAgo(status.lastEvent)}`
					: "No webhook events received"}
			</span>
			{!status.connected && (
				<a
					href={appSettingsUrl}
					target="_blank"
					rel="noopener noreferrer"
					className={styles.webhookConfigure}
				>
					Configure
				</a>
			)}
		</div>
	);
}
