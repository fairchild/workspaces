import type { Agent } from "@/lib/types";
import styles from "./agent-card.module.css";

interface AgentCardProps {
	agent: Agent;
}

export function AgentCard({ agent }: AgentCardProps) {
	const isActive = agent.status === "active";

	return (
		<div className={`${styles.card} ${isActive ? styles.cardActive : ""}`}>
			<div className={styles.header}>
				<div className={styles.identity}>
					<span className={styles.name}>{agent.name}</span>
					{agent.role && <span className={styles.role}>{agent.role}</span>}
				</div>
				<div className={styles.status}>
					<span
						className={`${styles.statusDot} ${isActive ? styles.statusDotActive : ""}`}
					/>
					<span
						className={`${styles.statusLabel} ${isActive ? styles.statusLabelActive : ""}`}
					>
						{isActive ? "Active" : "Idle"}
					</span>
				</div>
			</div>

			{agent.skills.length > 0 && (
				<div className={styles.skills}>
					{agent.skills.map((skill) => (
						<span key={skill} className={styles.skill}>
							{skill}
						</span>
					))}
				</div>
			)}
		</div>
	);
}
