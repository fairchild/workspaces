"use client";

import type { EventStats } from "@/lib/events";
import type { WebhookEvent } from "@/lib/types";
import { useCallback, useEffect, useState } from "react";
import { ActivityFeed } from "./components/activity-feed";
import { MainPanel } from "./components/main-panel";
import { Sidebar } from "./components/sidebar";
import styles from "./page.module.css";

type Tab = "repos" | "overview" | "activity";

const POLL_INTERVAL = 15_000;

export default function Dashboard() {
	const [activeTab, setActiveTab] = useState<Tab>("overview");
	const [stats, setStats] = useState<EventStats | null>(null);
	const [events, setEvents] = useState<WebhookEvent[]>([]);

	const fetchData = useCallback(async () => {
		const [statsRes, eventsRes] = await Promise.allSettled([
			fetch("/api/events/stats"),
			fetch("/api/events"),
		]);
		if (statsRes.status === "fulfilled" && statsRes.value.ok)
			setStats(await statsRes.value.json());
		if (eventsRes.status === "fulfilled" && eventsRes.value.ok)
			setEvents(await eventsRes.value.json());
	}, []);

	useEffect(() => {
		fetchData();
		const id = setInterval(fetchData, POLL_INTERVAL);
		return () => clearInterval(id);
	}, [fetchData]);

	return (
		<>
			<div className={styles.columns}>
				<aside
					className={`${styles.panel} ${styles.left} ${activeTab === "repos" ? styles.mobileVisible : ""}`}
				>
					<Sidebar repos={stats?.repos ?? []} />
				</aside>
				<main
					className={`${styles.panel} ${styles.center} ${activeTab === "overview" ? styles.mobileVisible : ""}`}
				>
					<MainPanel stats={stats} />
				</main>
				<aside
					className={`${styles.panel} ${styles.right} ${activeTab === "activity" ? styles.mobileVisible : ""}`}
				>
					<ActivityFeed events={events} />
				</aside>
			</div>

			<nav className={styles.tabBar}>
				<button
					type="button"
					className={`${styles.tab} ${activeTab === "repos" ? styles.tabActive : ""}`}
					onClick={() => setActiveTab("repos")}
				>
					<svg
						className={styles.tabIcon}
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						strokeWidth="2"
						aria-hidden="true"
					>
						<path d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z" />
					</svg>
					<span>Repos</span>
				</button>
				<button
					type="button"
					className={`${styles.tab} ${activeTab === "overview" ? styles.tabActive : ""}`}
					onClick={() => setActiveTab("overview")}
				>
					<svg
						className={styles.tabIcon}
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						strokeWidth="2"
						aria-hidden="true"
					>
						<rect x="3" y="3" width="7" height="7" rx="1" />
						<rect x="14" y="3" width="7" height="7" rx="1" />
						<rect x="3" y="14" width="7" height="7" rx="1" />
						<rect x="14" y="14" width="7" height="7" rx="1" />
					</svg>
					<span>Overview</span>
				</button>
				<button
					type="button"
					className={`${styles.tab} ${activeTab === "activity" ? styles.tabActive : ""}`}
					onClick={() => setActiveTab("activity")}
				>
					<svg
						className={styles.tabIcon}
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						strokeWidth="2"
						aria-hidden="true"
					>
						<polyline points="22,12 18,12 15,21 9,3 6,12 2,12" />
					</svg>
					<span>Activity</span>
				</button>
			</nav>
		</>
	);
}
