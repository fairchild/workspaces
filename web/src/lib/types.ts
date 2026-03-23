export type WorkspaceStatus =
	| "provisioning"
	| "active"
	| "stopped"
	| "archived";

/** Mirrors Swift `GitStatus` raw values from Models.swift */
export type GitStatus = "M" | "A" | "D" | "?" | "R";

export interface Repo {
	id: string;
	name: string;
	localPath: string;
	remoteURL: string | null;
	addedAt: string;
	lastAccessedAt: string;
}

/** Subset of Swift Workspace model — flattens sourceRepo relationship into repoId/repoName */
export interface Workspace {
	id: string;
	name: string;
	path: string;
	repoId: string | null;
	repoName: string | null;
	createdAt: string;
	lastAccessedAt: string;
	status: WorkspaceStatus;
	gitBranch: string | null;
	backendIdentifier: string;
}

export interface GitChange {
	path: string;
	status: GitStatus;
}

export interface WebhookEvent {
	id: string;
	type: WebhookEventType;
	action: string;
	summary: string;
	repo: string;
	timestamp: string;
}

export type WebhookEventType =
	| "pull_request"
	| "check_run"
	| "check_suite"
	| "discussion"
	| "discussion_comment"
	| "push"
	| "issues"
	| "issue_comment"
	| "workflow_run";

export const WORKSPACE_STATUS_LABELS: Record<WorkspaceStatus, string> = {
	provisioning: "Provisioning",
	active: "Active",
	stopped: "Stopped",
	archived: "Archived",
};

export const WEBHOOK_EVENT_ICONS: Record<WebhookEventType, string> = {
	pull_request: "git-pull-request",
	check_run: "check-circle",
	check_suite: "check-circle",
	discussion: "message-square",
	discussion_comment: "message-circle",
	push: "git-commit",
	issues: "circle-dot",
	issue_comment: "message-circle",
	workflow_run: "play-circle",
};
