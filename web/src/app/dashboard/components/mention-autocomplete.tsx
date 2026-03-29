"use client";

import type { Agent } from "@/lib/types";
import { useEffect, useRef, useState } from "react";
import styles from "./mention-autocomplete.module.css";

interface MentionAutocompleteProps {
	query: string;
	agents: Agent[];
	onSelect: (agent: Agent) => void;
	onDismiss: () => void;
}

export function MentionAutocomplete({
	query,
	agents,
	onSelect,
	onDismiss,
}: MentionAutocompleteProps) {
	const [activeIndex, setActiveIndex] = useState(0);
	const listRef = useRef<HTMLDivElement>(null);

	const filtered = agents.filter((a) =>
		a.name.toLowerCase().startsWith(query.toLowerCase()),
	);

	useEffect(() => {
		setActiveIndex(0);
	}, [query]);

	useEffect(() => {
		const handleKey = (e: KeyboardEvent) => {
			if (e.key === "ArrowDown") {
				e.preventDefault();
				setActiveIndex((i) => Math.min(i + 1, filtered.length - 1));
			} else if (e.key === "ArrowUp") {
				e.preventDefault();
				setActiveIndex((i) => Math.max(i - 1, 0));
			} else if (e.key === "Enter" || e.key === "Tab") {
				e.preventDefault();
				if (filtered[activeIndex]) onSelect(filtered[activeIndex]);
			} else if (e.key === "Escape") {
				e.preventDefault();
				onDismiss();
			}
		};
		window.addEventListener("keydown", handleKey);
		return () => window.removeEventListener("keydown", handleKey);
	}, [activeIndex, filtered, onSelect, onDismiss]);

	useEffect(() => {
		const el = listRef.current?.children[activeIndex] as
			| HTMLElement
			| undefined;
		el?.scrollIntoView({ block: "nearest" });
	}, [activeIndex]);

	if (filtered.length === 0) {
		return (
			<div className={styles.overlay}>
				<div className={styles.empty}>No matching agents</div>
			</div>
		);
	}

	return (
		<div className={styles.overlay}>
			<div className={styles.list} ref={listRef}>
				{filtered.map((agent, i) => (
					<div
						key={agent.name}
						className={`${styles.item} ${i === activeIndex ? styles.itemActive : ""}`}
						onMouseDown={(e) => {
							e.preventDefault();
							onSelect(agent);
						}}
						onMouseEnter={() => setActiveIndex(i)}
					>
						<span
							className={`${styles.itemDot} ${agent.status === "active" ? styles.itemDotActive : ""}`}
						/>
						<div className={styles.itemInfo}>
							<span className={styles.itemName}>
								@{agent.name}
							</span>
							{agent.role && (
								<span className={styles.itemRole}>
									{agent.role}
								</span>
							)}
						</div>
					</div>
				))}
			</div>
		</div>
	);
}
