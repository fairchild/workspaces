"use client";

import type { Agent, TimelineEntry } from "@/lib/types";
import { useCallback, useEffect, useRef, useState } from "react";
import styles from "./chat-panel.module.css";
import { ComposeBar } from "./compose-bar";
import { MessageList } from "./message-list";

const POLL_INTERVAL = 5_000;

interface AgentSessionInfo {
	agentName: string;
	streamUrl: string;
	threadId: string;
}

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
	const [streamingMessage, setStreamingMessage] = useState<{
		agentName: string;
		content: string;
		status:
			| "sending"
			| "connecting"
			| "provisioning"
			| "thinking"
			| "streaming";
	} | null>(null);
	const lastCountRef = useRef(0);
	const abortRef = useRef<AbortController | null>(null);

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

	// Clean up active stream on unmount
	useEffect(() => {
		return () => {
			abortRef.current?.abort();
		};
	}, []);

	const connectToAgentStream = useCallback(
		async (session: AgentSessionInfo & { message: string }) => {
			abortRef.current?.abort();
			const controller = new AbortController();
			abortRef.current = controller;

			setStreamingMessage((prev) => ({
				agentName: session.agentName,
				content: "",
				status: prev?.status === "sending" ? "connecting" : "provisioning",
			}));

			try {
				const res = await fetch(session.streamUrl, {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({
						repo,
						agentName: session.agentName,
						message: session.message,
						threadId: session.threadId,
					}),
					signal: controller.signal,
				});

				if (!res.ok || !res.body) {
					setStreamingMessage(null);
					return;
				}

				const reader = res.body.getReader();
				const decoder = new TextDecoder();
				let buffer = "";
				let streamDone = false;

				while (!streamDone) {
					const { done, value } = await reader.read();
					if (done) break;

					buffer += decoder.decode(value, { stream: true });
					const lines = buffer.split("\n");
					buffer = lines.pop() ?? "";

					for (const line of lines) {
						if (!line.startsWith("data: ")) continue;
						try {
							const chunk = JSON.parse(line.slice(6));
							if (chunk.type === "text") {
								setStreamingMessage((prev) =>
									prev
										? {
												...prev,
												content: prev.content + chunk.content,
												status: "streaming",
											}
										: null,
								);
							} else if (chunk.type === "status") {
								const s = chunk.content?.includes("Starting")
									? "provisioning"
									: "thinking";
								setStreamingMessage((prev) =>
									prev ? { ...prev, status: s as typeof prev.status } : null,
								);
							} else if (chunk.type === "done" || chunk.type === "error") {
								streamDone = true;
								break;
							}
						} catch {
							// skip malformed SSE lines
						}
					}
				}
			} catch (err) {
				if (err instanceof DOMException && err.name === "AbortError") return;
			} finally {
				setStreamingMessage(null);
				abortRef.current = null;
				// Refresh timeline to pick up persisted agent response
				await fetchTimeline();
			}
		},
		[repo, fetchTimeline],
	);

	const handleSend = useCallback(
		async (message: string, agentName?: string) => {
			if (!repo || streamingMessage) return;

			// Optimistic: show message immediately
			const optimisticEntry: TimelineEntry = {
				kind: "chat",
				id: `optimistic-${Date.now()}`,
				repo,
				author: "you",
				authorType: "user",
				content: message,
				agentTarget: agentName ?? null,
				discussionId: null,
				discussionUrl: null,
				timestamp: new Date().toISOString(),
			};
			setEntries((prev) => [...prev, optimisticEntry]);

			if (agentName) {
				setStreamingMessage({
					agentName,
					content: "",
					status: "sending",
				});
			}

			let data: Record<string, unknown>;
			try {
				const res = await fetch("/api/chat/messages", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ repo, message, agentName }),
				});
				if (!res.ok) {
					setStreamingMessage(null);
					await fetchTimeline(); // revert optimistic
					return;
				}
				data = await res.json();
			} catch {
				setStreamingMessage(null);
				await fetchTimeline(); // revert optimistic
				return;
			}

			if (data.agentSession) {
				// Agent session — connect to SSE stream
				await fetchTimeline(); // Replace optimistic with server version
				await connectToAgentStream({
					...(data.agentSession as AgentSessionInfo),
					message,
				});
			} else {
				// Regular message — just refresh
				await fetchTimeline();
			}
		},
		[repo, fetchTimeline, connectToAgentStream, streamingMessage],
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
			<MessageList
				entries={entries}
				loading={loading}
				streamingMessage={streamingMessage}
			/>
			<ComposeBar repo={repo as string} agents={agents} onSend={handleSend} />
		</div>
	);
}
