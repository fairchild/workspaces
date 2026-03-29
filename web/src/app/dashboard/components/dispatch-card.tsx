import type { ChatMessage } from "@/lib/types";
import styles from "./dispatch-card.module.css";
import { formatTime } from "./timeline-utils";

interface DispatchCardProps {
	message: ChatMessage;
}

export function DispatchCard({ message }: DispatchCardProps) {
	return (
		<div className={styles.card}>
			<div className={styles.header}>
				<div className={styles.agent}>
					<span className={styles.agentChip}>
						@{message.agentTarget}
					</span>
					<span className={styles.author}>{message.author}</span>
				</div>
				<span className={styles.time}>
					{formatTime(message.timestamp)}
				</span>
			</div>
			<span className={styles.content}>{message.content}</span>
			{message.discussionUrl && (
				<a
					href={message.discussionUrl}
					target="_blank"
					rel="noopener noreferrer"
					className={styles.discussionLink}
				>
					view discussion →
				</a>
			)}
		</div>
	);
}
