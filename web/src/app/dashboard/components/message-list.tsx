"use client";

import type { DispatchMetadata, TimelineEntry } from "@/lib/types";
import { useEffect, useRef } from "react";
import { DispatchCard, tryParseDispatchMetadata } from "./dispatch-card";
import styles from "./message-list.module.css";
import { StatusCard } from "./status-card";
import { formatTime } from "./timeline-utils";

interface MessageListProps {
	entries: TimelineEntry[];
	loading: boolean;
}

function dayKey(timestamp: string): string {
	return new Date(timestamp).toLocaleDateString("en-US", {
		month: "short",
		day: "numeric",
	});
}

function shouldShowDay(entries: TimelineEntry[], index: number): boolean {
	if (index === 0) return true;
	const prev = entries[index - 1];
	const curr = entries[index];
	return dayKey(prev.timestamp) !== dayKey(curr.timestamp);
}

export function MessageList({ entries, loading }: MessageListProps) {
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
				{entries.map((entry, i) => (
					<div key={entry.id}>
						{shouldShowDay(entries, i) && (
							<div className={styles.daySeparator}>
								<span className={styles.dayLabel}>
									{dayKey(entry.timestamp)}
								</span>
							</div>
						)}
						{entry.kind === "event" ? (
							<StatusCard event={entry} />
						) : entry.agentTarget && tryParseDispatchMetadata(entry.content) ? (
							<DispatchCard
								metadata={
									tryParseDispatchMetadata(entry.content) as DispatchMetadata
								}
							/>
						) : (
							<ChatMessageRow message={entry} />
						)}
					</div>
				))}
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

	return (
		<div className={styles.message}>
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
