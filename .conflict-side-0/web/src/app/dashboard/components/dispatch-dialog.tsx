"use client";

import { useCallback, useEffect } from "react";
import styles from "./dispatch-dialog.module.css";

interface DispatchDialogProps {
	agent: string;
	task: string;
	repo: string;
	issueRef: string | null;
	onConfirm: () => void;
	onCancel: () => void;
	sending: boolean;
}

export function DispatchDialog({
	agent,
	task,
	repo,
	issueRef,
	onConfirm,
	onCancel,
	sending,
}: DispatchDialogProps) {
	const handleKeyDown = useCallback(
		(e: KeyboardEvent) => {
			if (e.key === "Escape" && !sending) onCancel();
		},
		[onCancel, sending],
	);

	useEffect(() => {
		document.addEventListener("keydown", handleKeyDown);
		return () => document.removeEventListener("keydown", handleKeyDown);
	}, [handleKeyDown]);

	return (
		// biome-ignore lint/a11y/useKeyWithClickEvents: Escape key handled via document listener
		<div className={styles.backdrop} onClick={sending ? undefined : onCancel}>
			{/* biome-ignore lint/a11y/useKeyWithClickEvents: keyboard handled on backdrop */}
			<div className={styles.dialog} onClick={(e) => e.stopPropagation()}>
				<h3 className={styles.title}>Dispatch to @{agent}</h3>

				<div className={styles.body}>
					<div className={styles.field}>
						<span className={styles.fieldLabel}>Agent</span>
						<span className={styles.fieldValue}>@{agent}</span>
					</div>
					<div className={styles.field}>
						<span className={styles.fieldLabel}>Repo</span>
						<span className={styles.fieldValue}>{repo}</span>
					</div>
					<div className={styles.field}>
						<span className={styles.fieldLabel}>Task</span>
						<span className={styles.fieldValue}>{task}</span>
					</div>
					{issueRef && (
						<div className={styles.field}>
							<span className={styles.fieldLabel}>Issue</span>
							<span className={styles.fieldValue}>{issueRef}</span>
						</div>
					)}
				</div>

				<p className={styles.hint}>
					This will create a GitHub Discussion for the agent to pick up.
				</p>

				<div className={styles.actions}>
					<button
						type="button"
						className={styles.cancelBtn}
						onClick={onCancel}
						disabled={sending}
					>
						Cancel
					</button>
					<button
						type="button"
						className={styles.confirmBtn}
						onClick={onConfirm}
						disabled={sending}
					>
						{sending ? "Dispatching..." : "Dispatch"}
					</button>
				</div>
			</div>
		</div>
	);
}
