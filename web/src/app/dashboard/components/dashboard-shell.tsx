"use client";

import type { AgentDiscoveryResponse, SelectedRepo } from "@/lib/types";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import styles from "../page.module.css";
import { ActivityFeed } from "./activity-feed";
import { ChatPanel } from "./chat-panel";
import { MainPanel } from "./main-panel";
import { Sidebar } from "./sidebar";
import { TerminalPanel } from "./terminal-panel";

type TabId = "dashboard" | "chat" | "terminal";

const TABS: { id: TabId; label: string }[] = [
	{ id: "dashboard", label: "Dashboard" },
	{ id: "chat", label: "Chat" },
	{ id: "terminal", label: "Terminal" },
];

const VALID_TABS = new Set<string>(TABS.map((t) => t.id));

function isValidTab(value: string | undefined): value is TabId {
	return !!value && VALID_TABS.has(value);
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

	// Shared across Terminal and Chat tabs — which agent's session is focused.
	// Persisted in the URL so switching main tabs preserves the agent context.
	const selectedAgent = searchParams.get("agent");

	const [unreadChat, setUnreadChat] = useState(false);
	const [leftCollapsed, setLeftCollapsed] = useState(false);
	const [rightCollapsed, setRightCollapsed] = useState(false);

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

	const setSelectedAgent = useCallback(
		(agentName: string | null) => {
			const params = new URLSearchParams(searchParams.toString());
			if (agentName) {
				params.set("agent", agentName);
			} else {
				params.delete("agent");
			}
			const qs = params.toString();
			router.replace(`${pathname}${qs ? `?${qs}` : ""}`, { scroll: false });
		},
		[pathname, router, searchParams],
	);

	// Keyboard shortcuts
	useEffect(() => {
		const handleKeyDown = (e: KeyboardEvent) => {
			if (e.metaKey && e.key === "b" && !e.shiftKey) {
				e.preventDefault();
				setLeftCollapsed((v) => !v);
			}
			if (e.metaKey && e.shiftKey && e.key === "b") {
				e.preventDefault();
				setRightCollapsed((v) => !v);
			}
			if (e.metaKey && e.key === "1") {
				e.preventDefault();
				setTab("dashboard");
			}
			if (e.metaKey && e.key === "2") {
				e.preventDefault();
				setTab("chat");
			}
			if (e.metaKey && e.key === "3") {
				e.preventDefault();
				setTab("terminal");
			}
		};
		window.addEventListener("keydown", handleKeyDown);
		return () => window.removeEventListener("keydown", handleKeyDown);
	}, [setTab]);

	// Clear unread badge when switching to chat
	useEffect(() => {
		if (activeTab === "chat") setUnreadChat(false);
	}, [activeTab]);

	const activeTabRef = useRef(activeTab);
	useEffect(() => {
		activeTabRef.current = activeTab;
	}, [activeTab]);

	const handleNewChatMessage = useCallback(() => {
		if (activeTabRef.current !== "chat") setUnreadChat(true);
	}, []);

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

	useEffect(() => {
		let cancelled = false;

		async function loadAgentData() {
			if (!selectedRepo) {
				setAgentData(null);
				setError(null);
				setLoading(false);
				return;
			}

			setLoading(true);
			setError(null);
			try {
				const res = await fetch(
					`/api/repos/${selectedRepo.owner}/${selectedRepo.repo}/agents`,
				);
				if (cancelled) return;
				if (res.ok) {
					setAgentData(await res.json());
				} else {
					const body = await res.json().catch(() => ({}));
					if (cancelled) return;
					setAgentData(null);
					setError(
						body.needsReauth
							? "Please sign out and sign back in to grant repository access."
							: `Failed to load agent data: ${body.error ?? res.statusText}`,
					);
				}
			} catch {
				if (!cancelled) setError("Failed to connect");
			} finally {
				if (!cancelled) setLoading(false);
			}
		}

		void loadAgentData();
		return () => {
			cancelled = true;
		};
	}, [selectedRepo]);

	return (
		<div
			className={[
				styles.columns,
				leftCollapsed && styles.columnsLeftCollapsed,
				rightCollapsed && styles.columnsRightCollapsed,
				leftCollapsed && rightCollapsed && styles.columnsBothCollapsed,
			]
				.filter(Boolean)
				.join(" ")}
		>
			{/* Panel toggle affordances */}
			<button
				type="button"
				className={`${styles.panelToggle} ${leftCollapsed ? styles.leftToggleCollapsed : styles.leftToggle}`}
				onClick={() => setLeftCollapsed((v) => !v)}
				title="Toggle sidebar (Cmd+B)"
			>
				{leftCollapsed ? "\u25B8" : "\u25C2"}
			</button>
			<button
				type="button"
				className={`${styles.panelToggle} ${rightCollapsed ? styles.rightToggleCollapsed : styles.rightToggle}`}
				onClick={() => setRightCollapsed((v) => !v)}
				title="Toggle activity panel (Cmd+Shift+B)"
			>
				{rightCollapsed ? "\u25C2" : "\u25B8"}
			</button>
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
				) : activeTab === "chat" ? (
					<ChatPanel
						selectedRepo={selectedRepo}
						agents={agentData?.agents ?? []}
						onNewMessage={handleNewChatMessage}
						selectedAgent={selectedAgent}
						onSelectAgent={setSelectedAgent}
					/>
				) : (
					<TerminalPanel
						selectedRepo={selectedRepo}
						selectedAgent={selectedAgent}
						onSelectAgent={setSelectedAgent}
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
