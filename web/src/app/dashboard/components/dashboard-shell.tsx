"use client";

import type { AgentDiscoveryResponse, SelectedRepo } from "@/lib/types";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import styles from "../page.module.css";
import { ActivityFeed } from "./activity-feed";
import { ChatPanel } from "./chat-panel";
import { MainPanel } from "./main-panel";
import { Sidebar } from "./sidebar";

type TabId = "dashboard" | "chat";

const TABS: { id: TabId; label: string }[] = [
	{ id: "dashboard", label: "Dashboard" },
	{ id: "chat", label: "Chat" },
];

function isValidTab(value: string | undefined): value is TabId {
	return value === "dashboard" || value === "chat";
}

interface DashboardShellProps {
	selectedRepo: { owner: string; repo: string } | null;
	initialTab?: string;
}

export function DashboardShell({
	selectedRepo,
	initialTab,
}: DashboardShellProps) {
	const router = useRouter();
	const pathname = usePathname();
	const searchParams = useSearchParams();

	const activeTab: TabId = isValidTab(searchParams.get("tab") ?? undefined)
		? (searchParams.get("tab") as TabId)
		: isValidTab(initialTab)
			? initialTab
			: "dashboard";

	const [unreadChat, setUnreadChat] = useState(false);

	const setTab = useCallback(
		(tab: TabId) => {
			const params = new URLSearchParams(searchParams.toString());
			if (tab === "dashboard") {
				params.delete("tab");
			} else {
				params.set("tab", tab);
			}
			const qs = params.toString();
			router.replace(`${pathname}${qs ? `?${qs}` : ""}`, { scroll: false });
		},
		[pathname, router, searchParams],
	);

	// Clear unread badge when switching to chat
	useEffect(() => {
		if (activeTab === "chat") setUnreadChat(false);
	}, [activeTab]);

	const handleNewChatMessage = useCallback(() => {
		if (activeTab !== "chat") setUnreadChat(true);
	}, [activeTab]);

	const [repos, setRepos] = useState<SelectedRepo[]>([]);
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
			.catch((err) => console.warn("[dashboard] repos fetch failed:", err));
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
				<Sidebar repos={repos} selectedRepo={selectedRepo} />
			</aside>
			<main className={styles.center}>
				<nav className={styles.tabBar}>
					{TABS.map(({ id, label }) => (
						<button
							key={id}
							type="button"
							className={`${styles.tab} ${activeTab === id ? styles.tabActive : ""}`}
							onClick={() => setTab(id)}
						>
							{label}
							{id === "chat" && unreadChat && (
								<span className={styles.unreadBadge} />
							)}
						</button>
					))}
				</nav>
				{activeTab === "dashboard" ? (
					<MainPanel
						agentData={agentData}
						selectedRepo={selectedRepo}
						loading={loading}
						error={error}
					/>
				) : (
					<ChatPanel
						selectedRepo={selectedRepo}
						agents={agentData?.agents ?? []}
						onNewMessage={handleNewChatMessage}
					/>
				)}
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
