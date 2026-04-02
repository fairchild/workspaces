"use client";

import styles from "./streaming-bubble.module.css";

type StreamingStatus =
	| "sending"
	| "connecting"
	| "provisioning"
	| "thinking"
	| "streaming";

const STATUS_LABELS: Record<StreamingStatus, string> = {
	sending: "Sending...",
	connecting: "Connecting",
	provisioning: "Starting sandbox...",
	thinking: "Thinking...",
	streaming: "",
};

interface StreamingBubbleProps {
	message: {
		agentName: string;
		content: string;
		status: StreamingStatus;
	} | null;
}

export function StreamingBubble({ message }: StreamingBubbleProps) {
	if (!message) return null;

	return (
		<div className={styles.bubble}>
			<div className={styles.header}>
				<span className={styles.author}>{message.agentName}</span>
				<span className={styles.time}>now</span>
			</div>
			{message.content ? (
				<span className={styles.content}>{message.content}</span>
			) : (
				<span className={styles.indicator}>
					{STATUS_LABELS[message.status] ||
						`Connecting to @${message.agentName}...`}
				</span>
			)}
		</div>
	);
}
