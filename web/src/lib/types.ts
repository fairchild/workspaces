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

// --- Agent discovery ---

export interface SelectedRepo {
	owner: string;
	repo: string;
	addedAt: string;
}

export type AgentStatus = "active" | "idle";

export interface Agent {
	name: string;
	role: string | null;
	status: AgentStatus;
	skills: string[];
	lastAction: string | null;
}

export interface Skill {
	name: string;
	description: string;
}

export interface ConfigFile {
	path: string;
	description: string;
}

export interface PipelineIssue {
	number: number;
	title: string;
	labels: string[];
	assignee: string | null;
	url: string;
}

export type PipelineColumn = "ready" | "claimed" | "review" | "mergeable";

export interface Pipeline {
	ready: PipelineIssue[];
	claimed: PipelineIssue[];
	review: PipelineIssue[];
	mergeable: PipelineIssue[];
}

export interface AgentDiscoveryResponse {
	agents: Agent[];
	skills: Skill[];
	configFiles: ConfigFile[];
	pipeline: Pipeline;
	stats: {
		agentCount: number;
		skillCount: number;
		openPRs: number;
		readyIssues: number;
	};
}

export const PIPELINE_LABELS: Record<PipelineColumn, string> = {
	ready: "Ready",
	claimed: "Claimed",
	review: "Review",
	mergeable: "Mergeable",
};

export const PIPELINE_GITHUB_LABELS: Record<PipelineColumn, string> = {
	ready: "agent:ready",
	claimed: "agent:claimed",
	review: "agent:review",
	mergeable: "agent:mergeable",
};

export interface GitHubRepo {
	full_name: string;
	owner: string;
	name: string;
	pushed_at: string;
	description: string | null;
	hasAgents?: boolean;
	agentCount?: number;
}
