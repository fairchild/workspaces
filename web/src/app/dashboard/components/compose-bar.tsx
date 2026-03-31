"use client";

import type { Agent } from "@/lib/types";
import { useCallback, useEffect, useRef, useState } from "react";
import styles from "./compose-bar.module.css";
import { MentionAutocomplete } from "./mention-autocomplete";

interface ComposeBarProps {
	repo: string;
	agents: Agent[];
	onSend: (message: string, agentName?: string) => Promise<void>;
	disabled?: boolean;
}

export function ComposeBar({
	repo,
	agents,
	onSend,
	disabled,
}: ComposeBarProps) {
	const [text, setText] = useState("");
	const [agentTarget, setAgentTarget] = useState<string | null>(null);
	const [mentionQuery, setMentionQuery] = useState<string | null>(null);
	const [sending, setSending] = useState(false);
	const inputRef = useRef<HTMLTextAreaElement>(null);

	useEffect(() => {
		inputRef.current?.focus();
	}, []);

	const handleInput = useCallback((value: string) => {
		setText(value);

		// Detect @mention at current cursor position
		const textarea = inputRef.current;
		if (!textarea) return;
		const cursor = textarea.selectionStart;
		const before = value.slice(0, cursor);
		const match = before.match(/@(\w*)$/);

		if (match) {
			setMentionQuery(match[1]);
		} else {
			setMentionQuery(null);
		}
	}, []);

	const selectAgent = useCallback(
		(agent: Agent) => {
			setAgentTarget(agent.name);
			setMentionQuery(null);

			// Replace @query with @agentName in text
			const textarea = inputRef.current;
			if (!textarea) return;
			const cursor = textarea.selectionStart;
			const before = text.slice(0, cursor);
			const after = text.slice(cursor);
			const replaced = before.replace(/@\w*$/, `@${agent.name} `);
			setText(replaced + after);

			requestAnimationFrame(() => {
				textarea.focus();
				const pos = replaced.length;
				textarea.setSelectionRange(pos, pos);
			});
		},
		[text],
	);

	const clearAgent = useCallback(() => {
		setAgentTarget(null);
		inputRef.current?.focus();
	}, []);

	const dismissMention = useCallback(() => {
		setMentionQuery(null);
	}, []);

	const handleSend = useCallback(async () => {
		const trimmed = text.trim();
		if (!trimmed || sending) return;

		setSending(true);
		try {
			await onSend(trimmed, agentTarget ?? undefined);
			setText("");
			setAgentTarget(null);
			inputRef.current?.focus();
		} finally {
			setSending(false);
		}
	}, [text, agentTarget, sending, onSend]);

	const handleKeyDown = useCallback(
		(e: React.KeyboardEvent) => {
			// Let autocomplete handle arrow/enter/tab/escape when open
			if (mentionQuery !== null) return;

			if (e.key === "Enter" && !e.shiftKey) {
				e.preventDefault();
				handleSend();
			}
		},
		[mentionQuery, handleSend],
	);

	const canSend = text.trim().length > 0 && !sending && !disabled;

	return (
		<div className={styles.container}>
			{mentionQuery !== null && (
				<MentionAutocomplete
					query={mentionQuery}
					agents={agents}
					onSelect={selectAgent}
					onDismiss={dismissMention}
				/>
			)}

			{agentTarget && (
				<div className={styles.agentChipBar}>
					<span className={styles.agentChip}>
						@{agentTarget}
						<button
							type="button"
							className={styles.agentChipRemove}
							onClick={clearAgent}
							aria-label="Remove agent target"
						>
							×
						</button>
					</span>
				</div>
			)}

			<div className={styles.inputRow}>
				<textarea
					ref={inputRef}
					className={styles.input}
					value={text}
					onChange={(e) => handleInput(e.target.value)}
					onKeyDown={handleKeyDown}
					placeholder={
						agentTarget
							? `Message @${agentTarget}...`
							: "Type a message or @mention an agent..."
					}
					rows={1}
					disabled={disabled || sending}
				/>
				<button
					type="button"
					className={`${styles.sendBtn} ${canSend ? styles.sendBtnActive : ""}`}
					onClick={handleSend}
					disabled={!canSend}
				>
					{sending ? "..." : "Send"}
				</button>
			</div>

			<span className={styles.hint}>
				Enter to send · Shift+Enter for newline · @ to mention agent
			</span>
		</div>
	);
}
