import styles from "./chat-placeholder.module.css";

export function ChatPlaceholder() {
	return (
		<div className={styles.container}>
			<div className={styles.inner}>
				<span className={styles.icon}>&gt;_</span>
				<h2 className={styles.title}>Chat</h2>
				<p className={styles.hint}>Agent chat will appear here. Coming soon.</p>
			</div>
		</div>
	);
}
