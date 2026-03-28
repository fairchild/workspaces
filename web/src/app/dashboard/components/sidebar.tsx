"use client";

import type { AgentDiscoveryResponse, SelectedRepo } from "@/lib/types";
import Link from "next/link";
import { useEffect, useState } from "react";
import styles from "./sidebar.module.css";

interface SidebarProps {
	repos: SelectedRepo[];
	selectedRepo: { owner: string; repo: string } | null;
}

interface RepoAgentInfo {
	hasAgents: boolean;
	agentCount: number;
}

function RepoRow({
	repo,
	isSelected,
	agentInfo,
}: {
	repo: SelectedRepo;
	isSelected: boolean;
	agentInfo: RepoAgentInfo | undefined;
}) {
	const href = isSelected
		? "/dashboard"
		: `/dashboard/${repo.owner}/${repo.repo}`;

	return (
		<Link
			href={href}
			className={`${styles.row} ${isSelected ? styles.rowSelected : ""}`}
		>
			<span
				className={`${styles.statusDot} ${agentInfo?.hasAgents ? styles.statusActive : styles.statusInactive}`}
			/>
			<div className={styles.rowContent}>
				<span className={styles.rowName}>{repo.repo}</span>
			</div>
			{agentInfo?.hasAgents && (
				<span className={styles.agentBadge}>{agentInfo.agentCount}</span>
			)}
		</Link>
	);
}

export function Sidebar({ repos, selectedRepo }: SidebarProps) {
	const [collapsed, setCollapsed] = useState(!!selectedRepo);
	const [agentCache, setAgentCache] = useState<Map<string, RepoAgentInfo>>(
		new Map(),
	);

	// Fetch agent counts in background
	useEffect(() => {
		if (repos.length === 0) return;

		let cancelled = false;

		async function loadAgentInfo() {
			for (const repo of repos) {
				if (cancelled) return;
				try {
					const res = await fetch(
						`/api/repos/${repo.owner}/${repo.repo}/agents`,
					);
					if (res.ok && !cancelled) {
						const data: AgentDiscoveryResponse = await res.json();
						const key = `${repo.owner}/${repo.repo}`;
						setAgentCache((prev) => {
							const next = new Map(prev);
							next.set(key, {
								hasAgents: data.stats.agentCount > 0,
								agentCount: data.stats.agentCount,
							});
							return next;
						});
					}
				} catch {
					// Skip failed fetches
				}
			}
		}

		loadAgentInfo();
		return () => {
			cancelled = true;
		};
	}, [repos]);

	return (
		<div className={styles.sidebar}>
			<button
				type="button"
				className={styles.sectionHeader}
				onClick={() => setCollapsed((c) => !c)}
			>
				<div className={styles.sectionLeft}>
					<span
						className={`${styles.chevron} ${collapsed ? styles.chevronCollapsed : ""}`}
					>
						&#9662;
					</span>
					<span className={styles.sectionTitle}>Repos</span>
					{collapsed && selectedRepo && (
						<span className={styles.selectedLabel}>
							{selectedRepo.repo}
						</span>
					)}
				</div>
				<div className={styles.headerActions}>
					<span className={styles.count}>{repos.length}</span>
					<Link
						href="/setup?add=true"
						className={styles.addButton}
						onClick={(e) => e.stopPropagation()}
					>
						+
					</Link>
				</div>
			</button>

			{!collapsed && (
				<>
					{repos.length === 0 ? (
						<div className={styles.empty}>
							<span className={styles.emptyIcon}>&gt;_</span>
							<span className={styles.emptyText}>
								No repositories selected
							</span>
						</div>
					) : (
						<div className={styles.list}>
							{repos.map((repo) => {
								const key = `${repo.owner}/${repo.repo}`;
								const isSelected =
									selectedRepo?.owner === repo.owner &&
									selectedRepo?.repo === repo.repo;
								return (
									<RepoRow
										key={key}
										repo={repo}
										isSelected={isSelected}
										agentInfo={agentCache.get(key)}
									/>
								);
							})}
						</div>
					)}

					<div className={styles.addRow}>
						<Link href="/setup?add=true" className={styles.addRowLink}>
							<span className={styles.addRowPlus}>+</span>
							<span className={styles.addRowText}>Add repos</span>
						</Link>
					</div>
				</>
			)}
		</div>
	);
}
