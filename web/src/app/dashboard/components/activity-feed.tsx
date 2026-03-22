"use client";

import type { WebhookEvent, WebhookEventType } from "@/lib/types";
import { useCallback, useEffect, useState } from "react";
import styles from "./activity-feed.module.css";

const EVENT_COLORS: Record<WebhookEventType, string> = {
	pull_request: styles.eventPr,
	check_run: styles.eventCheck,
	check_suite: styles.eventCheck,
	discussion: styles.eventDiscussion,
	discussion_comment: styles.eventDiscussion,
	push: styles.eventPush,
	issues: styles.eventIssue,
	issue_comment: styles.eventIssue,
	workflow_run: styles.eventWorkflow,
};

const EVENT_LABELS: Record<WebhookEventType, string> = {
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

function formatTime(timestamp: string): string {
	const date = new Date(timestamp);
	const now = new Date();
	const diff = now.getTime() - date.getTime();
	const mins = Math.floor(diff / 60000);
	if (mins < 1) return "just now";
	if (mins < 60) return `${mins}m ago`;
	const hours = Math.floor(mins / 60);
	if (hours < 24) return `${hours}h ago`;
	return `${Math.floor(hours / 24)}d ago`;
}

function EventRow({ event }: { event: WebhookEvent }) {
	return (
		<div className={styles.event}>
			<div className={styles.eventHeader}>
				<span className={`${styles.eventBadge} ${EVENT_COLORS[event.type]}`}>
					{EVENT_LABELS[event.type]}
				</span>
				<span className={styles.eventTime}>{formatTime(event.timestamp)}</span>
			</div>
			<span className={styles.eventSummary}>{event.summary}</span>
			<span className={styles.eventRepo}>{event.repo}</span>
		</div>
	);
}

const POLL_INTERVAL = 10_000;

export function ActivityFeed() {
	const [events, setEvents] = useState<WebhookEvent[]>([]);

	const fetchEvents = useCallback(async () => {
		try {
			const res = await fetch("/api/events");
			if (res.ok) setEvents(await res.json());
		} catch {
			// Silently retry on next poll
		}
	}, []);

	useEffect(() => {
		fetchEvents();
		const id = setInterval(fetchEvents, POLL_INTERVAL);
		return () => clearInterval(id);
	}, [fetchEvents]);

	return (
		<div className={styles.feed}>
			<div className={styles.header}>
				<span className={styles.title}>Activity</span>
				<span className={styles.dot} />
			</div>

			{events.length === 0 ? (
				<div className={styles.empty}>
					<span className={styles.emptyText}>
						Webhook events will stream here
					</span>
				</div>
			) : (
				<div className={styles.list}>
					{events.map((event) => (
						<EventRow key={event.id} event={event} />
					))}
				</div>
			)}
		</div>
	);
}
