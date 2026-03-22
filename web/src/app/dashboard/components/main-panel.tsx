import styles from "./main-panel.module.css";

export function MainPanel({ userName }: { userName: string }) {
	return (
		<div className={styles.panel}>
			<div className={styles.welcome}>
				<h2 className={styles.greeting}>
					Hello, <span className={styles.name}>{userName}</span>
				</h2>
				<p className={styles.subtitle}>Your workspace overview</p>
			</div>

			<div className={styles.grid}>
				<StatCard label="Active" value="—" accent />
				<StatCard label="Stopped" value="—" />
				<StatCard label="Events today" value="—" />
				<StatCard label="Repos" value="—" />
			</div>

			<div className={styles.hint}>
				<span className={styles.hintChevron}>&gt;</span>
				<span className={styles.hintText}>
					Configure GitHub webhooks to start receiving events
				</span>
			</div>
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
