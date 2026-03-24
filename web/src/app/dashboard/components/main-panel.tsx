"use client";

import type { EventStats } from "@/lib/events";
import styles from "./main-panel.module.css";

export function MainPanel({ stats }: { stats: EventStats | null }) {
	return (
		<div className={styles.panel}>
			<div className={styles.welcome}>
				<h2 className={styles.greeting}>Your workspace overview</h2>
			</div>

			<div className={styles.grid}>
				<StatCard
					label="Events today"
					value={stats ? String(stats.eventsToday) : "—"}
					accent
				/>
				<StatCard
					label="Repos"
					value={stats ? String(stats.repos.length) : "—"}
				/>
			</div>

			{stats && stats.repos.length === 0 && (
				<div className={styles.hint}>
					<span className={styles.hintChevron}>&gt;</span>
					<span className={styles.hintText}>
						Configure GitHub webhooks to start receiving events
					</span>
				</div>
			)}
		</div>
	);
}

function StatCard({
	label,
	value,
	accent,
}: { label: string; value: string; accent?: boolean }) {
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
