"use client";

import styles from "./sidebar.module.css";

function RepoRow({ repo }: { repo: string }) {
	return (
		<div className={styles.row}>
			<span className={`${styles.statusDot} ${styles.statusActive}`} />
			<div className={styles.rowContent}>
				<span className={styles.rowName}>
					{repo.includes("/") ? repo.split("/")[1] : repo}
				</span>
				<span className={styles.rowBranch}>{repo}</span>
			</div>
		</div>
	);
}

export function Sidebar({ repos }: { repos: string[] }) {
	return (
		<div className={styles.sidebar}>
			<div className={styles.sectionHeader}>
				<span className={styles.sectionTitle}>Repos</span>
				<span className={styles.count}>{repos.length}</span>
			</div>

			{repos.length === 0 ? (
				<div className={styles.empty}>
					<span className={styles.emptyIcon}>&gt;_</span>
					<span className={styles.emptyText}>
						Repos will appear here when GitHub events arrive
					</span>
				</div>
			) : (
				<div className={styles.list}>
					{repos.map((repo) => (
						<RepoRow key={repo} repo={repo} />
					))}
				</div>
			)}
		</div>
	);
}
