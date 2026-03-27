import type { WebhookEventType } from "./types";

type Payload = Record<string, unknown>;
type Nested = Record<string, unknown> | undefined;

function str(val: unknown): string {
	return typeof val === "string" ? val : "";
}

function num(val: unknown): number {
	return typeof val === "number" ? val : 0;
}

export function getSourceUrl(type: WebhookEventType, p: Payload): string | null {
	switch (type) {
		case "pull_request":
			return str((p.pull_request as Nested)?.html_url) || null;
		case "issues":
			return str((p.issue as Nested)?.html_url) || null;
		case "issue_comment":
			return str((p.comment as Nested)?.html_url) || null;
		case "push":
			return str(p.compare) || null;
		case "check_run":
			return str((p.check_run as Nested)?.html_url) || null;
		case "check_suite": {
			const url = str((p.check_suite as Nested)?.url);
			if (url) {
				const repo = p.repository as Nested;
				return str(repo?.html_url)
					? `${str(repo?.html_url)}/actions`
					: null;
			}
			return null;
		}
		case "workflow_run":
			return str((p.workflow_run as Nested)?.html_url) || null;
		case "discussion":
			return str((p.discussion as Nested)?.html_url) || null;
		case "discussion_comment":
			return str((p.comment as Nested)?.html_url) || null;
		default:
			return null;
	}
}

export interface PRDetail {
	sender: string;
	title: string;
	body: string;
	additions: number;
	deletions: number;
	changedFiles: number;
}

export function extractPRDetail(p: Payload): PRDetail | null {
	const pr = p.pull_request as Nested;
	if (!pr) return null;
	return {
		sender: str((p.sender as Nested)?.login),
		title: str(pr.title),
		body: str(pr.body).slice(0, 200),
		additions: num(pr.additions),
		deletions: num(pr.deletions),
		changedFiles: num(pr.changed_files),
	};
}

export interface PushDetail {
	branch: string;
	commits: { sha: string; message: string }[];
}

export function extractPushDetail(p: Payload): PushDetail | null {
	const commits = p.commits as Array<Record<string, unknown>> | undefined;
	if (!commits) return null;
	return {
		branch: str(p.ref).replace("refs/heads/", ""),
		commits: commits.slice(0, 5).map((c) => ({
			sha: str(c.id).slice(0, 7),
			message: str(c.message).split("\n")[0],
		})),
	};
}

export interface CIDetail {
	name: string;
	conclusion: string;
	branch: string;
}

export function extractCIDetail(p: Payload): CIDetail | null {
	const run = (p.workflow_run ?? p.check_run ?? p.check_suite) as Nested;
	if (!run) return null;
	const branch =
		str(run.head_branch) ||
		str((run.head_sha as Nested)?.ref) ||
		"";
	return {
		name: str(run.name),
		conclusion: str(run.conclusion || run.status),
		branch,
	};
}

export interface IssueDetail {
	sender: string;
	title: string;
	body: string;
	labels: string[];
}

export function extractIssueDetail(p: Payload): IssueDetail | null {
	const issue = p.issue as Nested;
	if (!issue) return null;
	const labels = Array.isArray(issue.labels)
		? (issue.labels as Array<Record<string, unknown>>).map((l) => str(l.name))
		: [];
	return {
		sender: str((p.sender as Nested)?.login),
		title: str(issue.title),
		body: str(issue.body).slice(0, 200),
		labels,
	};
}

export interface DiscussionDetail {
	sender: string;
	title: string;
	body: string;
}

export function extractDiscussionDetail(p: Payload): DiscussionDetail | null {
	const disc = p.discussion as Nested;
	if (!disc) return null;
	return {
		sender: str((p.sender as Nested)?.login),
		title: str(disc.title),
		body: str(disc.body).slice(0, 200),
	};
}
