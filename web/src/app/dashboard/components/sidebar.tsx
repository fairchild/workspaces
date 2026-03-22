"use client";

import type { Workspace, WorkspaceStatus } from "@/lib/types";
import { WORKSPACE_STATUS_LABELS } from "@/lib/types";
import styles from "./sidebar.module.css";

const STATUS_INDICATOR: Record<WorkspaceStatus, string> = {
	active: styles.statusActive,
	provisioning: styles.statusProvisioning,
	stopped: styles.statusStopped,
	archived: styles.statusArchived,
};

function WorkspaceRow({ workspace }: { workspace: Workspace }) {
	return (
		<div className={styles.row}>
			<span
				className={`${styles.statusDot} ${STATUS_INDICATOR[workspace.status]}`}
				title={WORKSPACE_STATUS_LABELS[workspace.status]}
			/>
			<div className={styles.rowContent}>
				<span className={styles.rowName}>{workspace.name}</span>
				{workspace.gitBranch && (
					<span className={styles.rowBranch}>{workspace.gitBranch}</span>
				)}
			</div>
		</div>
	);
}

// Placeholder data until webhook integration
const PLACEHOLDER_WORKSPACES: Workspace[] = [];

export function Sidebar() {
	const workspaces = PLACEHOLDER_WORKSPACES;

	return (
		<div className={styles.sidebar}>
			<div className={styles.sectionHeader}>
				<span className={styles.sectionTitle}>Workspaces</span>
				<span className={styles.count}>{workspaces.length}</span>
			</div>

			{workspaces.length === 0 ? (
				<div className={styles.empty}>
					<span className={styles.emptyIcon}>&gt;_</span>
					<span className={styles.emptyText}>
						Workspaces will appear here when GitHub events arrive
					</span>
				</div>
			) : (
				<div className={styles.list}>
					{workspaces.map((ws) => (
						<WorkspaceRow key={ws.id} workspace={ws} />
					))}
				</div>
			)}
		</div>
	);
}
