"use client";

import styles from "./streaming-bubble.module.css";

type StreamingStatus =
	| "sending"
	| "connecting"
	| "provisioning"
	| "thinking"
	| "streaming"
	| "error";

const STATUS_LABELS: Record<StreamingStatus, string> = {
	sending: "Sending...",
	connecting: "Connecting",
	provisioning: "Starting sandbox...",
	thinking: "Thinking...",
	streaming: "",
	error: "",
};

interface StreamingBubbleProps {
	message: {
		agentName: string;
		content: string;
		lastTool?: string | null;
		status: StreamingStatus;
	} | null;
}

export function StreamingBubble({ message }: StreamingBubbleProps) {
	if (!message) return null;

	const isError = message.status === "error";

	return (
		<div className={`${styles.bubble} ${isError ? styles.error : ""}`}>
			<div className={styles.header}>
				<span className={isError ? styles.authorError : styles.author}>
					{message.agentName}
				</span>
				<span className={styles.time}>now</span>
			</div>
			{message.content ? (
				<span className={isError ? styles.contentError : styles.content}>
					{message.content}
				</span>
			) : (
				<span className={styles.indicator}>
					{STATUS_LABELS[message.status] ||
						`Connecting to @${message.agentName}...`}
				</span>
			)}
			{message.lastTool && !message.content && (
				<span className={styles.toolIndicator}>Using {message.lastTool}</span>
			)}
		</div>
	);
}
