import styles from "./page.module.css";

export default function Home() {
	return (
		<main className={styles.main}>
			{/* Background grid motif — echoes the 2x2 app icon */}
			<div className={styles.gridMotif} aria-hidden="true">
				<div className={styles.gridCell} />
				<div className={styles.gridCell} />
				<div className={styles.gridCell} />
				<div className={`${styles.gridCell} ${styles.gridCellActive}`}>
					<span className={styles.gridChevron}>&gt;</span>
				</div>
			</div>

			{/* Content */}
			<div className={styles.content}>
				{/* Wordmark */}
				<div className={styles.wordmarkRow}>
					<h1 className={styles.wordmark}>Spaces</h1>
					<span className={styles.cursor} />
				</div>

				{/* Tagline */}
				<p className={styles.tagline}>
					Workspace management for AI coding sessions
				</p>

				{/* Status readout */}
				<div className={styles.statusBar}>
					<div className={styles.statusItem}>
						<span className={styles.statusDot} />
						<span className={styles.statusLabel}>systems nominal</span>
					</div>
					<span className={styles.statusDivider}>|</span>
					<span className={styles.statusMeta}>spaces.cloudcompute.com</span>
				</div>

				{/* Footer links */}
				<nav className={styles.nav}>
					<a
						href="https://github.com/fairchild/workspaces"
						className={styles.navLink}
					>
						<span className={styles.navChevron}>&gt;</span> source
					</a>
				</nav>
			</div>
		</main>
	);
}
