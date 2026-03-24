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
			return;
		}
		setLoading(true);
		try {
			const res = await fetch(
				`/api/repos/${selectedRepo.owner}/${selectedRepo.repo}/agents`,
			);
			if (res.ok) setAgentData(await res.json());
		} catch {
			// retry on next select
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
