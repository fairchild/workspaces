"use client";

import type { Agent, TimelineEntry } from "@/lib/types";
import { useCallback, useEffect, useRef, useState } from "react";
import styles from "./chat-panel.module.css";
import { DispatchCard, tryParseDispatchMetadata } from "./dispatch-card";
import { DispatchDialog } from "./dispatch-dialog";

const POLL_INTERVAL = 10_000;
const BOT_COMMANDS = new Set(["status", "pipeline"]);

interface ChatPanelProps {
	selectedRepo: { owner: string; repo: string } | null;
	agents: Agent[];
}

interface PendingDispatch {
	agent: string;
	task: string;
	repo: string;
	issueRef: string | null;
}

export function ChatPanel({ selectedRepo, agents }: ChatPanelProps) {
	const [messages, setMessages] = useState<TimelineEntry[]>([]);
	const [input, setInput] = useState("");
	const [sending, setSending] = useState(false);
	const [showMentions, setShowMentions] = useState(false);
	const [mentionFilter, setMentionFilter] = useState("");
	const [pendingDispatch, setPendingDispatch] =
		useState<PendingDispatch | null>(null);
	const listRef = useRef<HTMLDivElement>(null);
	const inputRef = useRef<HTMLInputElement>(null);
	const autoScrollRef = useRef(true);

	const repoSlug = selectedRepo
		? `${selectedRepo.owner}/${selectedRepo.repo}`
		: null;

	// Fetch messages
	const fetchMessages = useCallback(
		async (since?: string) => {
			if (!repoSlug) return;
			const params = new URLSearchParams({ repo: repoSlug, limit: "50" });
			if (since) params.set("since", since);
			try {
				const res = await fetch(`/api/chat/messages?${params}`);
				if (!res.ok) return;
				const entries = (await res.json()) as TimelineEntry[];
				if (since) {
					setMessages((prev) => {
						const ids = new Set(prev.map((m) => m.id));
						const newItems = entries.filter((e) => !ids.has(e.id));
						return newItems.length > 0
							? [...prev, ...newItems].sort((a, b) =>
									a.timestamp > b.timestamp ? 1 : -1,
								)
							: prev;
					});
				} else {
					setMessages(
						[...entries].sort((a, b) => (a.timestamp > b.timestamp ? 1 : -1)),
					);
				}
			} catch {
				// Retry on next poll
			}
		},
		[repoSlug],
	);

	// Initial load
	useEffect(() => {
		setMessages([]);
		fetchMessages();
	}, [fetchMessages]);

	// Poll for new messages
	useEffect(() => {
		if (!repoSlug) return;
		const id = setInterval(() => {
			const latest =
				messages.length > 0
					? messages[messages.length - 1].timestamp
					: undefined;
			fetchMessages(latest);
		}, POLL_INTERVAL);
		return () => clearInterval(id);
	}, [repoSlug, messages, fetchMessages]);

	// Auto-scroll to bottom when new messages arrive
	const messageCount = messages.length;
	// biome-ignore lint/correctness/useExhaustiveDependencies: intentional trigger on messageCount
	useEffect(() => {
		if (autoScrollRef.current && listRef.current) {
			listRef.current.scrollTop = listRef.current.scrollHeight;
		}
	}, [messageCount]);

	const handleScroll = useCallback(() => {
		if (!listRef.current) return;
		const { scrollTop, scrollHeight, clientHeight } = listRef.current;
		autoScrollRef.current = scrollHeight - scrollTop - clientHeight < 40;
	}, []);

	// @mention parsing from input
	const handleInputChange = useCallback((value: string) => {
		setInput(value);
		const cursorMatch = value.match(/@(\w[\w-]*)$/);
		if (cursorMatch) {
			setMentionFilter(cursorMatch[1].toLowerCase());
			setShowMentions(true);
		} else if (value.endsWith("@")) {
			setMentionFilter("");
			setShowMentions(true);
		} else {
			setShowMentions(false);
		}
	}, []);

	const insertMention = useCallback(
		(name: string) => {
			const beforeAt = input.replace(/@[\w-]*$/, "");
			setInput(`${beforeAt}@${name} `);
			setShowMentions(false);
			inputRef.current?.focus();
		},
		[input],
	);

	const filteredAgents = [
		{ name: "spaces", role: "Bot commands" } as Agent,
		...agents,
	].filter((a) => a.name.toLowerCase().includes(mentionFilter));

	// Submit message
	const handleSubmit = useCallback(async () => {
		const trimmed = input.trim();
		if (!trimmed || !repoSlug || sending) return;

		const mentionMatch = trimmed.match(/^@(\w[\w-]*)\s*(.*)/);
		const agentName = mentionMatch?.[1] ?? null;
		const task = mentionMatch ? mentionMatch[2].trim() : trimmed;

		// If it's an agent dispatch (not a bot command), show confirmation dialog
		if (
			agentName &&
			agentName !== "spaces" &&
			!BOT_COMMANDS.has(task.toLowerCase())
		) {
			const issueMatch = task.match(/#(\d+)/);
			setPendingDispatch({
				agent: agentName,
				task,
				repo: repoSlug,
				issueRef: issueMatch ? `#${issueMatch[1]}` : null,
			});
			return;
		}

		// Direct send for bot commands and plain messages
		setSending(true);
		try {
			await fetch("/api/chat/messages", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({
					repo: repoSlug,
					message: trimmed,
					agentName,
				}),
			});
			setInput("");
			autoScrollRef.current = true;
			// Immediate refresh
			await fetchMessages();
		} catch {
			// Keep input on failure
		}
		setSending(false);
	}, [input, repoSlug, sending, fetchMessages]);

	// Dispatch confirmation
	const handleDispatchConfirm = useCallback(async () => {
		if (!pendingDispatch) return;
		setSending(true);
		try {
			await fetch("/api/chat/dispatch", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({
					repo: pendingDispatch.repo,
					agentName: pendingDispatch.agent,
					task: pendingDispatch.task,
					issueRef: pendingDispatch.issueRef,
				}),
			});
			setInput("");
			setPendingDispatch(null);
			autoScrollRef.current = true;
			await fetchMessages();
		} catch {
			// Keep dialog on failure
		}
		setSending(false);
	}, [pendingDispatch, fetchMessages]);

	const handleKeyDown = useCallback(
		(e: React.KeyboardEvent) => {
			if (e.key === "Enter" && !e.shiftKey) {
				e.preventDefault();
				handleSubmit();
			}
		},
		[handleSubmit],
	);

	if (!selectedRepo) {
		return (
			<div className={styles.panel}>
				<div className={styles.empty}>
					<span className={styles.emptyIcon}>&gt;_</span>
					<h2 className={styles.emptyTitle}>Chat</h2>
					<p className={styles.emptyHint}>
						Select a repo from the sidebar to chat with agents
					</p>
				</div>
			</div>
		);
	}

	return (
		<div className={styles.panel}>
			<div className={styles.messageList} ref={listRef} onScroll={handleScroll}>
				{messages.length === 0 ? (
					<div className={styles.empty}>
						<span className={styles.emptyIcon}>&gt;_</span>
						<p className={styles.emptyHint}>
							Type <code className={styles.code}>@agent task</code> to dispatch
							work, or <code className={styles.code}>@spaces status</code> for
							info
						</p>
					</div>
				) : (
					messages.map((entry) => <MessageRow key={entry.id} entry={entry} />)
				)}
			</div>

			<div className={styles.inputBar}>
				{showMentions && filteredAgents.length > 0 && (
					<div className={styles.mentionPopover}>
						{filteredAgents.map((agent) => (
							<button
								key={agent.name}
								type="button"
								className={styles.mentionItem}
								onMouseDown={(e) => {
									e.preventDefault();
									insertMention(agent.name);
								}}
							>
								<span className={styles.mentionName}>@{agent.name}</span>
								{agent.role && (
									<span className={styles.mentionRole}>{agent.role}</span>
								)}
							</button>
						))}
					</div>
				)}
				<input
					ref={inputRef}
					className={styles.inputField}
					type="text"
					value={input}
					onChange={(e) => handleInputChange(e.target.value)}
					onKeyDown={handleKeyDown}
					onBlur={() => setTimeout(() => setShowMentions(false), 150)}
					placeholder="@agent task description..."
					disabled={sending && !pendingDispatch}
				/>
				<button
					type="button"
					className={styles.sendBtn}
					onClick={handleSubmit}
					disabled={sending || !input.trim()}
				>
					Send
				</button>
			</div>

			{pendingDispatch && (
				<DispatchDialog
					agent={pendingDispatch.agent}
					task={pendingDispatch.task}
					repo={pendingDispatch.repo}
					issueRef={pendingDispatch.issueRef}
					onConfirm={handleDispatchConfirm}
					onCancel={() => setPendingDispatch(null)}
					sending={sending}
				/>
			)}
		</div>
	);
}

function formatTime(timestamp: string): string {
	const date = new Date(timestamp);
	const now = new Date();
	const diff = now.getTime() - date.getTime();
	const mins = Math.floor(diff / 60000);
	if (mins < 1) return "now";
	if (mins < 60) return `${mins}m`;
	const hours = Math.floor(mins / 60);
	if (hours < 24) return `${hours}h`;
	return `${Math.floor(hours / 24)}d`;
}

function MessageRow({ entry }: { entry: TimelineEntry }) {
	if (entry.kind === "event") {
		return (
			<div className={styles.eventRow}>
				<span className={styles.eventBadge}>
					{entry.type.replace("_", " ")}
				</span>
				<span className={styles.eventSummary}>{entry.summary}</span>
				<span className={styles.messageTime}>
					{formatTime(entry.timestamp)}
				</span>
			</div>
		);
	}

	// Check for dispatch card
	if (entry.authorType === "bot") {
		const metadata = tryParseDispatchMetadata(entry.content);
		if (metadata) {
			return (
				<div className={styles.message}>
					<div className={styles.messageHeader}>
						<span className={styles.authorBot}>{entry.author}</span>
						<span className={styles.messageTime}>
							{formatTime(entry.timestamp)}
						</span>
					</div>
					<DispatchCard metadata={metadata} />
				</div>
			);
		}
	}

	const isUser = entry.authorType === "user";
	const isBot = entry.authorType === "bot";

	return (
		<div className={styles.message}>
			<div className={styles.messageHeader}>
				<span
					className={
						isBot
							? styles.authorBot
							: isUser
								? styles.authorUser
								: styles.authorAgent
					}
				>
					{entry.author}
				</span>
				{entry.agentTarget && (
					<span className={styles.targetBadge}>@{entry.agentTarget}</span>
				)}
				<span className={styles.messageTime}>
					{formatTime(entry.timestamp)}
				</span>
			</div>
			<div className={styles.messageContent}>{entry.content}</div>
		</div>
	);
}
