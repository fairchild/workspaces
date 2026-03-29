"use client";

import type { Agent, TimelineEntry } from "@/lib/types";
import { useCallback, useEffect, useRef, useState } from "react";
import styles from "./chat-panel.module.css";
import { ComposeBar } from "./compose-bar";
import { MessageList } from "./message-list";

const POLL_INTERVAL = 5_000;

interface ChatPanelProps {
	selectedRepo: { owner: string; repo: string } | null;
	agents: Agent[];
	onNewMessage?: () => void;
}

export function ChatPanel({
	selectedRepo,
	agents,
	onNewMessage,
}: ChatPanelProps) {
	const [entries, setEntries] = useState<TimelineEntry[]>([]);
	const [loading, setLoading] = useState(false);
	const lastCountRef = useRef(0);

	const repo = selectedRepo
		? `${selectedRepo.owner}/${selectedRepo.repo}`
		: null;

	const fetchTimeline = useCallback(async () => {
		if (!repo) return;
		try {
			const res = await fetch(
				`/api/chat/messages?repo=${encodeURIComponent(repo)}&limit=100`,
			);
			if (res.ok) {
				const data: TimelineEntry[] = await res.json();
				setEntries(data);
				if (data.length > lastCountRef.current && lastCountRef.current > 0) {
					onNewMessage?.();
				}
				lastCountRef.current = data.length;
			}
		} catch {
			// retry on next poll
		}
	}, [repo, onNewMessage]);

	useEffect(() => {
		setEntries([]);
		lastCountRef.current = 0;
		if (!repo) return;

		setLoading(true);
		fetchTimeline().finally(() => setLoading(false));

		const id = setInterval(fetchTimeline, POLL_INTERVAL);
		return () => clearInterval(id);
	}, [repo, fetchTimeline]);

	const handleSend = useCallback(
		async (message: string, agentName?: string) => {
			if (!repo) return;
			const res = await fetch("/api/chat/messages", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ repo, message, agentName }),
			});
			if (res.ok) {
				// Immediately refetch to show the new message
				await fetchTimeline();
			}
		},
		[repo, fetchTimeline],
	);

	if (!selectedRepo) {
		return (
			<div className={styles.noRepo}>
				<span className={styles.noRepoIcon}>&gt;_</span>
				<span className={styles.noRepoText}>
					Select a repository from the sidebar to start chatting with agents.
				</span>
			</div>
		);
	}

	return (
		<div className={styles.panel}>
			<MessageList entries={entries} loading={loading} />
			<ComposeBar repo={repo as string} agents={agents} onSend={handleSend} />
		</div>
	);
}
