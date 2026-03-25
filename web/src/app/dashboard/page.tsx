"use client";

import type { AgentDiscoveryResponse, SelectedRepo } from "@/lib/types";
import { useCallback, useEffect, useState } from "react";
import { ActivityFeed } from "./components/activity-feed";
import { MainPanel } from "./components/main-panel";
import { Sidebar } from "./components/sidebar";
import styles from "./page.module.css";

export default function Dashboard() {
	const [repos, setRepos] = useState<SelectedRepo[]>([]);
	const [selectedRepo, setSelectedRepo] = useState<{
		owner: string;
		repo: string;
	} | null>(null);
	const [agentData, setAgentData] = useState<AgentDiscoveryResponse | null>(
		null,
	);
	const [loading, setLoading] = useState(false);
	const [error, setError] = useState<string | null>(null);

	// Fetch saved repos on mount
	useEffect(() => {
		fetch("/api/repos")
			.then((r) => r.json())
			.then(setRepos)
			.catch(() => {});
	}, []);

	// Fetch agent data when selectedRepo changes
	const fetchAgentData = useCallback(async () => {
		if (!selectedRepo) {
			setAgentData(null);
			setError(null);
			return;
		}
		setLoading(true);
		setError(null);
		try {
			const res = await fetch(
				`/api/repos/${selectedRepo.owner}/${selectedRepo.repo}/agents`,
			);
			if (res.ok) {
				setAgentData(await res.json());
			} else {
				const body = await res.json().catch(() => ({}));
				setAgentData(null);
				setError(
					body.needsReauth
						? "Please sign out and sign back in to grant repository access."
						: `Failed to load agent data: ${body.error ?? res.statusText}`,
				);
			}
		} catch {
			setError("Failed to connect");
		}
		setLoading(false);
	}, [selectedRepo]);

	useEffect(() => {
		fetchAgentData();
	}, [fetchAgentData]);

	return (
		<div className={styles.columns}>
			<aside className={styles.left}>
				<Sidebar
					repos={repos}
					selectedRepo={selectedRepo}
					onSelectRepo={setSelectedRepo}
				/>
			</aside>
			<main className={styles.center}>
				<MainPanel
					agentData={agentData}
					selectedRepo={selectedRepo}
					loading={loading}
					error={error}
				/>
			</main>
			<aside className={styles.right}>
				<ActivityFeed
					filterRepo={
						selectedRepo ? `${selectedRepo.owner}/${selectedRepo.repo}` : null
					}
				/>
			</aside>
		</div>
	);
}
