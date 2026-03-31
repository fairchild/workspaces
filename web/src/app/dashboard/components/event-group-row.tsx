"use client";

import type { WebhookEvent, WebhookEventType } from "@/lib/types";
import { useState } from "react";
import styles from "./event-group-row.module.css";
import { TYPE_COLOR, TYPE_LABEL } from "./status-card";
import { formatTime } from "./timeline-utils";

const COUNT_BADGE: Record<string, string> = {
	ci: styles.countBadgeCi,
	pr: styles.countBadgePr,
	push: styles.countBadgePush,
	discussion: styles.countBadgeDiscussion,
	issue: styles.countBadgeIssue,
};

interface EventGroupRowProps {
	events: WebhookEvent[];
}

export function EventGroupRow({ events }: EventGroupRowProps) {
	const [expanded, setExpanded] = useState(false);

	const counts = new Map<string, { count: number; color: string }>();
	for (const e of events) {
		const label = TYPE_LABEL[e.type];
		const color = TYPE_COLOR[e.type];
		const existing = counts.get(label);
		counts.set(label, {
			count: (existing?.count ?? 0) + 1,
			color: existing?.color ?? color,
		});
	}

	const oldest = events[0].timestamp;
	const newest = events[events.length - 1].timestamp;
	const timeStr =
		oldest === newest
			? formatTime(newest)
			: `${formatTime(oldest)} – ${formatTime(newest)}`;

	return (
		<div className={styles.group} onClick={() => setExpanded(!expanded)}>
			<div className={styles.collapsed}>
				<span
					className={`${styles.chevron} ${expanded ? styles.chevronOpen : ""}`}
				>
					&#9656;
				</span>
				<div className={styles.badges}>
					{[...counts.entries()].map(([label, { count, color }]) => (
						<span
							key={label}
							className={`${styles.countBadge} ${COUNT_BADGE[color] ?? ""}`}
						>
							{label} &times;{count}
						</span>
					))}
				</div>
				<span className={styles.timeRange}>{timeStr}</span>
			</div>
			{expanded && (
				<div className={styles.expandedList}>
					{events.map((e) => (
						<ExpandedEventItem key={e.id} event={e} />
					))}
				</div>
			)}
		</div>
	);
}

function ExpandedEventItem({ event }: { event: WebhookEvent }) {
	const color = TYPE_COLOR[event.type];
	const badgeClass = COUNT_BADGE[color] ?? "";

	return (
		<div className={styles.expandedItem}>
			<span className={`${styles.expandedBadge} ${badgeClass}`}>
				{TYPE_LABEL[event.type]}
			</span>
			<span className={styles.expandedSummary}>{event.summary}</span>
			<span className={styles.expandedTime}>
				{formatTime(event.timestamp)}
			</span>
		</div>
	);
}
