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
	const [agentCache, setAgentCache] = useState<Map<string, RepoAgentInfo>>(
		new Map(),
	);

	// Fetch agent counts in background
	useEffect(() => {
		if (repos.length === 0) {
			setAgentCache(new Map());
			return;
		}

		let cancelled = false;

		async function loadAgentInfo() {
			const repoKeys = new Set(
				repos.map((repo) => `${repo.owner}/${repo.repo}`),
			);
			const results = await Promise.all(
				repos.map(async (repo) => {
					if (cancelled) return null;
					try {
						const res = await fetch(
							`/api/repos/${repo.owner}/${repo.repo}/agents`,
						);
						if (!res.ok || cancelled) return null;
						const data: AgentDiscoveryResponse = await res.json();
						return {
							key: `${repo.owner}/${repo.repo}`,
							value: {
								hasAgents: data.stats.agentCount > 0,
								agentCount: data.stats.agentCount,
							},
						};
					} catch {
						// Skip failed fetches
						return null;
					}
				}),
			);
			if (cancelled) return;
			setAgentCache((prev) => {
				const next = new Map([...prev].filter(([key]) => repoKeys.has(key)));
				for (const result of results) {
					if (result) next.set(result.key, result.value);
				}
				return next;
			});
		}

		void loadAgentInfo();
		return () => {
			cancelled = true;
		};
	}, [repos]);

	return (
		<div className={styles.sidebar}>
			<div className={styles.sectionHeader}>
				<span className={styles.sectionTitle}>Repos</span>
				<div className={styles.headerActions}>
					<span className={styles.count}>{repos.length}</span>
					<Link href="/setup?add=true" className={styles.addButton}>
						+
					</Link>
				</div>
			</div>

			{repos.length === 0 ? (
				<div className={styles.empty}>
					<span className={styles.emptyIcon}>&gt;_</span>
					<span className={styles.emptyText}>No repositories selected</span>
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
		</div>
	);
}
