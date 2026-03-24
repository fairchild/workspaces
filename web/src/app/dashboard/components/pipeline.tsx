import type {
	PipelineColumn,
	PipelineIssue,
	Pipeline as PipelineType,
} from "@/lib/types";
import { PIPELINE_LABELS } from "@/lib/types";
import styles from "./pipeline.module.css";

interface PipelineProps {
	pipeline: PipelineType;
}

const COLUMN_ORDER: PipelineColumn[] = [
	"ready",
	"claimed",
	"review",
	"mergeable",
];

const COLUMN_STYLE: Record<PipelineColumn, string> = {
	ready: styles.columnReady,
	claimed: styles.columnClaimed,
	review: styles.columnReview,
	mergeable: styles.columnMergeable,
};

function IssueCard({ issue }: { issue: PipelineIssue }) {
	const hasTask = issue.labels.some((l) => l === "agent:task");
	const hasDecision = issue.labels.some((l) => l === "agent:decision");

	return (
		<a
			href={issue.url}
			target="_blank"
			rel="noopener noreferrer"
			className={styles.issue}
		>
			<span className={styles.issueTitle}>{issue.title}</span>
			<div className={styles.issueMeta}>
				<span className={styles.issueNumber}>#{issue.number}</span>
				{issue.assignee && (
					<span className={styles.issueAssignee}>@{issue.assignee}</span>
				)}
				{hasTask && <span className={styles.labelTask}>task</span>}
				{hasDecision && <span className={styles.labelDecision}>decision</span>}
			</div>
		</a>
	);
}

export function PipelineBoard({ pipeline }: PipelineProps) {
	return (
		<div className={styles.pipeline}>
			{COLUMN_ORDER.map((col) => {
				const issues = pipeline[col];
				return (
					<div key={col} className={`${styles.column} ${COLUMN_STYLE[col]}`}>
						<div className={styles.columnHeader}>
							<span className={styles.columnLabel}>{PIPELINE_LABELS[col]}</span>
							<span className={styles.columnCount}>{issues.length}</span>
						</div>
						{issues.length === 0 ? (
							<div className={styles.empty}>No issues</div>
						) : (
							issues.map((issue) => (
								<IssueCard key={issue.number} issue={issue} />
							))
						)}
					</div>
				);
			})}
		</div>
	);
}
