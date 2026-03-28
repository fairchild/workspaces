import type { DispatchMetadata, DispatchStatus } from "@/lib/types";
import styles from "./dispatch-card.module.css";

const STATUS_CONFIG: Record<
	DispatchStatus,
	{ label: string; className: string }
> = {
	pending: { label: "Pending", className: styles.statusPending },
	running: { label: "Running", className: styles.statusRunning },
	pr_opened: { label: "PR Opened", className: styles.statusPr },
	ci_passed: { label: "CI Passed", className: styles.statusPassed },
	complete: { label: "Complete", className: styles.statusComplete },
	failed: { label: "Failed", className: styles.statusFailed },
};

interface DispatchCardProps {
	metadata: DispatchMetadata;
}

export function DispatchCard({ metadata }: DispatchCardProps) {
	const statusInfo = STATUS_CONFIG[metadata.status] ?? STATUS_CONFIG.pending;

	return (
		<div className={styles.card}>
			<div className={styles.header}>
				<div className={styles.identity}>
					<span className={styles.agent}>@{metadata.agent}</span>
					<span className={styles.task}>{metadata.task}</span>
				</div>
				<div className={styles.statusArea}>
					<span className={`${styles.statusDot} ${statusInfo.className}`} />
					<span className={`${styles.statusLabel} ${statusInfo.className}`}>
						{statusInfo.label}
					</span>
				</div>
			</div>

			<div className={styles.fields}>
				<span className={styles.field}>
					<span className={styles.fieldLabel}>Task</span>
					<span className={styles.fieldValue}>{metadata.taskId}</span>
				</span>
				{metadata.branch && (
					<span className={styles.field}>
						<span className={styles.fieldLabel}>Branch</span>
						<span className={styles.fieldValue}>{metadata.branch}</span>
					</span>
				)}
				{metadata.issueRef && (
					<span className={styles.field}>
						<span className={styles.fieldLabel}>Issue</span>
						<span className={styles.fieldValue}>{metadata.issueRef}</span>
					</span>
				)}
			</div>

			<div className={styles.links}>
				{metadata.discussionUrl && (
					<a
						href={metadata.discussionUrl}
						target="_blank"
						rel="noopener noreferrer"
						className={styles.link}
					>
						Discussion
					</a>
				)}
				{metadata.prUrl && (
					<a
						href={metadata.prUrl}
						target="_blank"
						rel="noopener noreferrer"
						className={styles.link}
					>
						Pull Request
					</a>
				)}
			</div>
		</div>
	);
}

export function tryParseDispatchMetadata(
	content: string,
): DispatchMetadata | null {
	try {
		const parsed = JSON.parse(content);
		if (parsed?.type === "dispatch") return parsed as DispatchMetadata;
	} catch {
		// Not dispatch metadata
	}
	return null;
}
