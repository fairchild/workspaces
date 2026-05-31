export type PrReviewContractEventType =
	| "pull_request"
	| "issue_comment"
	| "pull_request_review_comment";

export type ExpectedPrReviewTriggerKind =
	| "opened"
	| "reopened"
	| "ready_for_review"
	| "synchronize"
	| "edited"
	| "evidence_comment";

export interface PrReviewWebhookContractCase {
	name: string;
	deliveryId: string;
	eventType: PrReviewContractEventType;
	payload: Record<string, unknown>;
	expectedForwarded: boolean;
	expectedTriggerKind: ExpectedPrReviewTriggerKind | null;
}

const repo = {
	full_name: "fairchild/workspaces",
	html_url: "https://github.com/fairchild/workspaces",
	name: "workspaces",
};

const humanSender = { login: "fairchild", type: "User" };
const botSender = { login: "workspaces-claude-pr-reviewer[bot]", type: "Bot" };

function pullRequestPayload(
	action: string,
	number: number,
	overrides: {
		pull_request?: Record<string, unknown>;
		changes?: Record<string, unknown>;
		sender?: Record<string, unknown>;
	} = {},
): Record<string, unknown> {
	const headSha = `abc${String(number).padStart(4, "0")}def456`;
	return {
		action,
		sender: overrides.sender ?? humanSender,
		repository: repo,
		pull_request: {
			number,
			title: `Contract PR ${number}`,
			html_url: `https://github.com/fairchild/workspaces/pull/${number}`,
			body: "## Evidence\n- [x] Contract fixture",
			head: { ref: `contract-pr-${number}`, sha: headSha },
			base: { ref: "main" },
			draft: false,
			...overrides.pull_request,
		},
		...(overrides.changes ? { changes: overrides.changes } : {}),
	};
}

function issueCommentPayload(
	number: number,
	body: string,
	overrides: {
		issue?: Record<string, unknown>;
		sender?: Record<string, unknown>;
		comment?: Record<string, unknown>;
	} = {},
): Record<string, unknown> {
	return {
		action: "created",
		sender: overrides.sender ?? humanSender,
		repository: repo,
		issue: {
			number,
			title: `Contract PR ${number}`,
			html_url: `https://github.com/fairchild/workspaces/pull/${number}`,
			body: "PR description",
			pull_request: {
				html_url: `https://github.com/fairchild/workspaces/pull/${number}`,
			},
			...overrides.issue,
		},
		comment: {
			id: 900000 + number,
			body,
			html_url: `https://github.com/fairchild/workspaces/pull/${number}#issuecomment-${900000 + number}`,
			created_at: "2026-05-13T12:00:00Z",
			user: humanSender,
			...overrides.comment,
		},
	};
}

function reviewCommentPayload(number: number): Record<string, unknown> {
	return {
		action: "created",
		sender: humanSender,
		repository: repo,
		pull_request: {
			number,
			html_url: `https://github.com/fairchild/workspaces/pull/${number}`,
		},
		comment: {
			id: 910000 + number,
			body: "Could this be simpler?",
			html_url: `https://github.com/fairchild/workspaces/pull/${number}#discussion_r${910000 + number}`,
			created_at: "2026-05-13T12:00:00Z",
			user: humanSender,
		},
	};
}

export const PR_REVIEW_WEBHOOK_CONTRACT_CASES: PrReviewWebhookContractCase[] = [
	{
		name: "ready PR opened",
		deliveryId: "contract-pr-opened",
		eventType: "pull_request",
		payload: pullRequestPayload("opened", 8101),
		expectedForwarded: true,
		expectedTriggerKind: "opened",
	},
	{
		name: "draft PR opened",
		deliveryId: "contract-pr-opened-draft",
		eventType: "pull_request",
		payload: pullRequestPayload("opened", 8102, {
			pull_request: { draft: true },
		}),
		expectedForwarded: false,
		expectedTriggerKind: null,
	},
	{
		name: "ready PR reopened",
		deliveryId: "contract-pr-reopened",
		eventType: "pull_request",
		payload: pullRequestPayload("reopened", 8103),
		expectedForwarded: true,
		expectedTriggerKind: "reopened",
	},
	{
		name: "draft PR marked ready",
		deliveryId: "contract-pr-ready-for-review",
		eventType: "pull_request",
		payload: pullRequestPayload("ready_for_review", 8104),
		expectedForwarded: true,
		expectedTriggerKind: "ready_for_review",
	},
	{
		name: "new head synchronized",
		deliveryId: "contract-pr-synchronize",
		eventType: "pull_request",
		payload: pullRequestPayload("synchronize", 8105, {
			pull_request: {
				head: { ref: "contract-pr-8105", sha: "newsha8105abc" },
			},
		}),
		expectedForwarded: true,
		expectedTriggerKind: "synchronize",
	},
	{
		name: "draft PR synchronized",
		deliveryId: "contract-pr-synchronize-draft",
		eventType: "pull_request",
		payload: pullRequestPayload("synchronize", 8106, {
			pull_request: { draft: true },
		}),
		expectedForwarded: false,
		expectedTriggerKind: null,
	},
	{
		name: "PR body edited",
		deliveryId: "contract-pr-edited-body",
		eventType: "pull_request",
		payload: pullRequestPayload("edited", 8107, {
			changes: { body: { from: "old description" } },
		}),
		expectedForwarded: true,
		expectedTriggerKind: "edited",
	},
	{
		name: "PR base edited",
		deliveryId: "contract-pr-edited-base",
		eventType: "pull_request",
		payload: pullRequestPayload("edited", 8108, {
			pull_request: { base: { ref: "release/2026-05" } },
			changes: { base: { ref: { from: "main" } } },
		}),
		expectedForwarded: true,
		expectedTriggerKind: "edited",
	},
	{
		name: "PR title edited",
		deliveryId: "contract-pr-edited-title",
		eventType: "pull_request",
		payload: pullRequestPayload("edited", 8109, {
			changes: { title: { from: "old title" } },
		}),
		expectedForwarded: false,
		expectedTriggerKind: null,
	},
	{
		name: "PR label added",
		deliveryId: "contract-pr-labeled",
		eventType: "pull_request",
		payload: pullRequestPayload("labeled", 8114),
		expectedForwarded: false,
		expectedTriggerKind: null,
	},
	{
		name: "PR closed",
		deliveryId: "contract-pr-closed",
		eventType: "pull_request",
		payload: pullRequestPayload("closed", 8115),
		expectedForwarded: false,
		expectedTriggerKind: null,
	},
	{
		name: "reviewer bot synchronized",
		deliveryId: "contract-pr-bot-sender",
		eventType: "pull_request",
		payload: pullRequestPayload("synchronize", 8110, {
			sender: botSender,
		}),
		expectedForwarded: false,
		expectedTriggerKind: null,
	},
	{
		name: "evidence PR comment created",
		deliveryId: "contract-pr-evidence-comment",
		eventType: "issue_comment",
		payload: issueCommentPayload(
			8111,
			"Evidence: https://evidence.cloudcompute.com/workspaces/pr-8111.png",
		),
		expectedForwarded: true,
		expectedTriggerKind: "evidence_comment",
	},
	{
		name: "non-evidence PR comment created",
		deliveryId: "contract-pr-plain-comment",
		eventType: "issue_comment",
		payload: issueCommentPayload(8112, "looks good"),
		expectedForwarded: false,
		expectedTriggerKind: null,
	},
	{
		name: "evidence issue comment created",
		deliveryId: "contract-issue-evidence-comment",
		eventType: "issue_comment",
		payload: issueCommentPayload(8113, "Evidence: attached", {
			issue: { pull_request: undefined },
		}),
		expectedForwarded: false,
		expectedTriggerKind: null,
	},
	{
		name: "PR review comment created",
		deliveryId: "contract-pr-review-comment",
		eventType: "pull_request_review_comment",
		payload: reviewCommentPayload(8116),
		expectedForwarded: false,
		expectedTriggerKind: null,
	},
];
