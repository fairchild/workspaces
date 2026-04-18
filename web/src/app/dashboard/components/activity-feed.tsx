"use client";

import { formatRelativeTime } from "@/lib/timeline-utils";
import type { WebhookEvent, WebhookEventType } from "@/lib/types";
import { useCallback, useEffect, useState } from "react";
import styles from "./activity-feed.module.css";
import { EventDetail } from "./event-detail";
import { TYPE_LABEL } from "./event-utils";

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

function EventRow({
	event,
	isExpanded,
	showRepo,
	onToggle,
}: {
	event: WebhookEvent;
	isExpanded: boolean;
	showRepo: boolean;
	onToggle: () => void;
}) {
	return (
		<>
			<button
				type="button"
				className={`${styles.event} ${isExpanded ? styles.eventExpanded : ""}`}
				onClick={onToggle}
			>
				<div className={styles.eventHeader}>
					<span className={`${styles.eventBadge} ${EVENT_COLORS[event.type]}`}>
						{TYPE_LABEL[event.type]}
					</span>
					<span className={styles.eventTime}>
						{formatRelativeTime(event.timestamp)}
					</span>
				</div>
				<span className={styles.eventSummary}>{event.summary}</span>
				{showRepo && <span className={styles.eventRepo}>{event.repo}</span>}
			</button>
			{isExpanded && <EventDetail eventId={event.id} eventType={event.type} />}
		</>
	);
}

const POLL_INTERVAL = 10_000;

interface ActivityFeedProps {
	filterRepo?: string | null;
}

export function ActivityFeed({ filterRepo }: ActivityFeedProps) {
	const [events, setEvents] = useState<WebhookEvent[]>([]);
	const [expandedId, setExpandedId] = useState<string | null>(null);

	const fetchEvents = useCallback(() => {
		let cancelled = false;
		return {
			run: async () => {
				try {
					const url = filterRepo
						? `/api/events?repo=${encodeURIComponent(filterRepo)}`
						: "/api/events";
					const res = await fetch(url);
					if (!res.ok || cancelled) return;
					const data: WebhookEvent[] = await res.json();
					if (cancelled) return;
					setEvents((prev) =>
						prev.length === data.length &&
						prev[0]?.id === data[0]?.id &&
						prev[prev.length - 1]?.id === data[data.length - 1]?.id
							? prev
							: data,
					);
				} catch {
					// Silently retry on next poll
				}
			},
			cancel: () => {
				cancelled = true;
			},
		};
	}, [filterRepo]);

	useEffect(() => {
		const request = fetchEvents();
		void request.run();
		const id = setInterval(() => {
			void request.run();
		}, POLL_INTERVAL);
		return () => {
			request.cancel();
			clearInterval(id);
		};
	}, [fetchEvents]);

	// Collapse when repo filter changes
	// biome-ignore lint/correctness/useExhaustiveDependencies: intentional reset on filter change
	useEffect(() => {
		setExpandedId(null);
	}, [filterRepo]);

	return (
		<div className={styles.feed}>
			<div className={styles.header}>
				<span className={styles.title}>
					Activity{filterRepo ? ` — ${filterRepo.split("/").pop()}` : ""}
				</span>
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
						<EventRow
							key={event.id}
							event={event}
							isExpanded={expandedId === event.id}
							showRepo={!filterRepo}
							onToggle={() =>
								setExpandedId((prev) => (prev === event.id ? null : event.id))
							}
						/>
					))}
				</div>
			)}
		</div>
	);
}
