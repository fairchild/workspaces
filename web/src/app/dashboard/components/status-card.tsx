import type { WebhookEvent, WebhookEventType } from "@/lib/types";
import styles from "./status-card.module.css";
import { formatTime } from "./timeline-utils";

export const TYPE_LABEL: Record<WebhookEventType, string> = {
	pull_request: "PR",
	check_run: "CI",
	check_suite: "CI",
	discussion: "DISC",
	discussion_comment: "DISC",
	push: "PUSH",
	issues: "ISSUE",
	issue_comment: "ISSUE",
	workflow_run: "CI",
};

type ColorKey = "ci" | "pr" | "push" | "discussion" | "issue";

export type { ColorKey };

export const TYPE_COLOR: Record<WebhookEventType, ColorKey> = {
	pull_request: "pr",
	check_run: "ci",
	check_suite: "ci",
	discussion: "discussion",
	discussion_comment: "discussion",
	push: "push",
	issues: "issue",
	issue_comment: "issue",
	workflow_run: "ci",
};

const INDICATOR: Record<ColorKey, string> = {
	ci: styles.indicatorCi,
	pr: styles.indicatorPr,
	push: styles.indicatorPush,
	discussion: styles.indicatorDiscussion,
	issue: styles.indicatorIssue,
};

const BADGE: Record<ColorKey, string> = {
	ci: styles.badgeCi,
	pr: styles.badgePr,
	push: styles.badgePush,
	discussion: styles.badgeDiscussion,
	issue: styles.badgeIssue,
};

interface StatusCardProps {
	event: WebhookEvent;
}

export function StatusCard({ event }: StatusCardProps) {
	const color = TYPE_COLOR[event.type];

	return (
		<div className={styles.card}>
			<div className={`${styles.indicator} ${INDICATOR[color]}`} />
			<div className={styles.body}>
				<div className={styles.row}>
					<span className={`${styles.badge} ${BADGE[color]}`}>
						{TYPE_LABEL[event.type]}
					</span>
					<span className={styles.time}>{formatTime(event.timestamp)}</span>
				</div>
				<span className={styles.summary}>{event.summary}</span>
			</div>
		</div>
	);
}
