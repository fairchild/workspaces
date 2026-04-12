import { formatCompactTime } from "@/lib/timeline-utils";
import type { WebhookEvent } from "@/lib/types";
import { type ColorKey, TYPE_COLOR, TYPE_LABEL } from "./event-utils";
import styles from "./status-card.module.css";

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
					<span className={styles.time}>
						{formatCompactTime(event.timestamp)}
					</span>
				</div>
				<span className={styles.summary}>{event.summary}</span>
			</div>
		</div>
	);
}
