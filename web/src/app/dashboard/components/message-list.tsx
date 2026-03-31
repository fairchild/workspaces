"use client";

import { dayKey } from "@/lib/timeline-utils";
import type {
	DispatchMetadata,
	TimelineEntry,
	WebhookEvent,
} from "@/lib/types";
import { useEffect, useMemo, useRef } from "react";
import { DispatchCard, tryParseDispatchMetadata } from "./dispatch-card";
import { EventGroupRow } from "./event-group-row";
import styles from "./message-list.module.css";
import { StatusCard } from "./status-card";
import { formatTime } from "./timeline-utils";

type GroupedEntry =
	| (TimelineEntry & { kind: "chat" })
	| { kind: "event"; entry: TimelineEntry & { kind: "event" } }
	| { kind: "event-group"; events: WebhookEvent[]; key: string };

function groupEntries(entries: TimelineEntry[]): GroupedEntry[] {
	const result: GroupedEntry[] = [];
	let currentGroup: WebhookEvent[] = [];

	const flushGroup = () => {
		if (currentGroup.length === 0) return;
		if (currentGroup.length === 1) {
			result.push({
				kind: "event",
				entry: { kind: "event", ...currentGroup[0] },
			});
		} else {
			result.push({
				kind: "event-group",
				events: currentGroup,
				key: currentGroup[0].id,
			});
		}
		currentGroup = [];
	};

	for (const entry of entries) {
		if (entry.kind === "event") {
			currentGroup.push(entry);
		} else {
			flushGroup();
			result.push(entry);
		}
	}
	flushGroup();
	return result;
}

interface StreamingMessage {
	agentName: string;
	content: string;
}

interface MessageListProps {
	entries: TimelineEntry[];
	loading: boolean;
	streamingMessage?: StreamingMessage | null;
}

export function MessageList({
	entries,
	loading,
	streamingMessage,
}: MessageListProps) {
	const anchorRef = useRef<HTMLDivElement>(null);
	const containerRef = useRef<HTMLDivElement>(null);
	const wasAtBottom = useRef(true);

	useEffect(() => {
		const el = containerRef.current;
		if (!el) return;
		const handleScroll = () => {
			wasAtBottom.current =
				el.scrollHeight - el.scrollTop - el.clientHeight < 40;
		};
		el.addEventListener("scroll", handleScroll, { passive: true });
		return () => el.removeEventListener("scroll", handleScroll);
	}, []);

	// biome-ignore lint/correctness/useExhaustiveDependencies: scroll on new entries
	useEffect(() => {
		if (wasAtBottom.current) {
			anchorRef.current?.scrollIntoView({ behavior: "smooth" });
		}
	}, [entries.length]);

	const grouped = useMemo(() => groupEntries(entries), [entries]);

	if (!loading && entries.length === 0) {
		return (
			<div className={styles.empty}>
				<span className={styles.emptyIcon}>&gt;_</span>
				<span className={styles.emptyText}>
					No messages yet. Use the compose bar below to dispatch an agent or
					start a conversation.
				</span>
			</div>
		);
	}

	return (
		<div className={styles.container} ref={containerRef}>
			<div className={styles.timeline}>
				{grouped.map((g, i) => {
					const key =
						g.kind === "event-group"
							? g.key
							: g.kind === "event"
								? g.entry.id
								: g.id;
					const ts =
						g.kind === "event-group"
							? g.events[0].timestamp
							: g.kind === "event"
								? g.entry.timestamp
								: g.timestamp;

					const prevTs = (() => {
						if (i === 0) return null;
						const prev = grouped[i - 1];
						if (prev.kind === "event-group")
							return prev.events[prev.events.length - 1].timestamp;
						if (prev.kind === "event") return prev.entry.timestamp;
						return prev.timestamp;
					})();

					const showDay = prevTs === null || dayKey(ts) !== dayKey(prevTs);

					return (
						<div key={key}>
							{showDay && (
								<div className={styles.daySeparator}>
									<span className={styles.dayLabel}>{dayKey(ts)}</span>
								</div>
							)}
							{g.kind === "event-group" ? (
								<EventGroupRow events={g.events} />
							) : g.kind === "event" ? (
								<StatusCard event={g.entry} />
							) : g.agentTarget && tryParseDispatchMetadata(g.content) ? (
								<DispatchCard
									metadata={
										tryParseDispatchMetadata(g.content) as DispatchMetadata
									}
								/>
							) : (
								<ChatMessageRow message={g} />
							)}
						</div>
					);
				})}
				{streamingMessage && (
					<div className={styles.message}>
						<div className={styles.messageHeader}>
							<span
								className={`${styles.messageAuthor} ${styles.messageAuthorAgent}`}
							>
								{streamingMessage.agentName}
							</span>
							<span className={styles.messageTime}>now</span>
						</div>
						<span className={styles.messageContent}>
							{streamingMessage.content || (
								<span className={styles.streamingIndicator}>thinking...</span>
							)}
						</span>
					</div>
				)}
			</div>
			<div ref={anchorRef} className={styles.anchor} />
		</div>
	);
}

function ChatMessageRow({
	message,
}: { message: TimelineEntry & { kind: "chat" } }) {
	const authorClass =
		message.authorType === "agent"
			? styles.messageAuthorAgent
			: message.authorType === "bot"
				? styles.messageAuthorBot
				: "";

	const isAgent = message.authorType === "agent";

	return (
		<div className={`${styles.message} ${isAgent ? styles.messageAgent : ""}`}>
			<div className={styles.messageHeader}>
				<span className={`${styles.messageAuthor} ${authorClass}`}>
					{message.author}
				</span>
				<span className={styles.messageTime}>
					{formatTime(message.timestamp)}
				</span>
			</div>
			<span className={styles.messageContent}>{message.content}</span>
			{message.discussionUrl && (
				<a
					href={message.discussionUrl}
					target="_blank"
					rel="noopener noreferrer"
					className={styles.messageDiscussionLink}
				>
					view discussion →
				</a>
			)}
		</div>
	);
}
