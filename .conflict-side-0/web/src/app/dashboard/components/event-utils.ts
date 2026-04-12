import type { WebhookEventType } from "@/lib/types";

type ColorKey = "ci" | "pr" | "push" | "discussion" | "issue";

export type { ColorKey };

export const TYPE_LABEL: Record<WebhookEventType, string> = {
	pull_request: "PR",
	check_run: "CI",
	check_suite: "CI",
	discussion: "DISC",
	discussion_comment: "DISC",
	push: "PUSH",
	issues: "ISSUE",
	issue_comment: "ISSUE",
	workflow_run: "CI",
};

export const TYPE_COLOR: Record<WebhookEventType, ColorKey> = {
	pull_request: "pr",
	check_run: "ci",
	check_suite: "ci",
	discussion: "discussion",
	discussion_comment: "discussion",
	push: "push",
	issues: "issue",
	issue_comment: "issue",
	workflow_run: "ci",
};
