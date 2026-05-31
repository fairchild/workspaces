import { createHash } from "node:crypto";
import type { PrReviewPayload, PrReviewTrigger } from "./pr-review";

export interface ParsedPrTrigger {
	reviewPayload: PrReviewPayload;
	context: PrReviewTrigger;
}

export type PrReviewTriggerClassificationKind =
	| "opened"
	| "reopened"
	| "ready_for_review"
	| "synchronize"
	| "body_edit"
	| "base_edit"
	| "metadata_edit"
	| "evidence_comment"
	| "non_evidence_comment"
	| "review_comment"
	| "label"
	| "closed"
	| "draft"
	| "bot_sender"
	| "malformed"
	| "unsupported";

type PrReviewTriggerSkipRelevance = "metadata" | "terminal" | "ignored";

interface BasePrReviewTriggerClassification {
	eventType: string;
	action: string;
	kind: PrReviewTriggerClassificationKind;
	reason: string;
}

export interface PrReviewTriggerMaterialClassification
	extends BasePrReviewTriggerClassification {
	decision: "trigger_review";
	relevance: "material";
	trigger: ParsedPrTrigger;
}

export interface PrReviewTriggerSkipClassification
	extends BasePrReviewTriggerClassification {
	decision: "skip_review";
	relevance: PrReviewTriggerSkipRelevance;
}

export type PrReviewTriggerClassification =
	| PrReviewTriggerMaterialClassification
	| PrReviewTriggerSkipClassification;

const EVIDENCE_SIGNAL =
	/(evidence\.cloudcompute\.com|^Evidence:|swift test|playwright|screenshot|recording|validation)/im;
const PR_REVIEWER_BOT_LOGIN = "workspaces-claude-pr-reviewer[bot]";

function isBotSender(payload: Record<string, unknown>): boolean {
	const sender = payload.sender as Record<string, unknown> | undefined;
	const login = String(sender?.login ?? "");
	if (login.endsWith("[bot]")) return true;
	if (String(sender?.type ?? "").toLowerCase() === "bot") return true;
	return false;
}

function buildReviewPayloadFromPr(
	pr: Record<string, unknown>,
	repoObj: Record<string, unknown>,
): PrReviewPayload | null {
	const head = pr.head as Record<string, unknown> | undefined;
	const base = pr.base as Record<string, unknown> | undefined;
	const number = Number(pr.number ?? 0);
	if (!number) return null;
	return {
		number,
		title: String(pr.title ?? ""),
		htmlUrl: String(pr.html_url ?? ""),
		body: String(pr.body ?? ""),
		headRef: String(head?.ref ?? ""),
		headSha: String(head?.sha ?? ""),
		baseRef: String(base?.ref ?? ""),
		repoUrl: String(repoObj.html_url ?? ""),
		repoFullName: String(repoObj.full_name ?? ""),
		repoName: String(repoObj.name ?? ""),
	};
}

function skipClassification(input: {
	eventType: string;
	action: string;
	kind: PrReviewTriggerClassificationKind;
	relevance?: PrReviewTriggerSkipRelevance;
	reason: string;
}): PrReviewTriggerSkipClassification {
	return {
		eventType: input.eventType,
		action: input.action,
		kind: input.kind,
		decision: "skip_review",
		relevance: input.relevance ?? "ignored",
		reason: input.reason,
	};
}

function materialClassification(input: {
	eventType: string;
	action: string;
	kind: PrReviewTriggerClassificationKind;
	reason: string;
	reviewPayload: PrReviewPayload;
	context: PrReviewTrigger;
}): PrReviewTriggerMaterialClassification {
	return {
		eventType: input.eventType,
		action: input.action,
		kind: input.kind,
		decision: "trigger_review",
		relevance: "material",
		reason: input.reason,
		trigger: {
			reviewPayload: input.reviewPayload,
			context: input.context,
		},
	};
}

export function classifyPrReviewTrigger(
	eventType: string,
	action: string,
	payload: Record<string, unknown>,
): PrReviewTriggerClassification {
	if (isBotSender(payload)) {
		return skipClassification({
			eventType,
			action,
			kind: "bot_sender",
			reason: "Bot-originated webhook events do not trigger managed reviews",
		});
	}

	if (eventType === "pull_request") {
		const pr = payload.pull_request as Record<string, unknown> | undefined;
		const repoObj = payload.repository as Record<string, unknown> | undefined;
		if (!pr || !repoObj) {
			return skipClassification({
				eventType,
				action,
				kind: "malformed",
				reason: "Pull request webhook is missing pull_request or repository",
			});
		}
		const reviewPayload = buildReviewPayloadFromPr(pr, repoObj);
		if (!reviewPayload) {
			return skipClassification({
				eventType,
				action,
				kind: "malformed",
				reason: "Pull request webhook is missing a PR number",
			});
		}

		const isDraft = Boolean(pr.draft);
		const draftSkip = (
			kind: PrReviewTriggerClassificationKind,
			reason: string,
		) =>
			skipClassification({
				eventType,
				action,
				kind,
				reason,
			});

		if (action === "opened") {
			if (isDraft) return draftSkip("draft", "Draft PR opened");
			return materialClassification({
				eventType,
				action,
				kind: "opened",
				reason: "PR opened",
				reviewPayload,
				context: {
					kind: "opened",
					triggerSourceId: reviewPayload.headSha || reviewPayload.headRef,
					reason: "PR opened",
				},
			});
		}
		if (action === "reopened") {
			if (isDraft) return draftSkip("draft", "Draft PR reopened");
			return materialClassification({
				eventType,
				action,
				kind: "reopened",
				reason: "PR reopened",
				reviewPayload,
				context: {
					kind: "reopened",
					triggerSourceId: reviewPayload.headSha || reviewPayload.headRef,
					reason: "PR reopened",
				},
			});
		}
		if (action === "ready_for_review") {
			return materialClassification({
				eventType,
				action,
				kind: "ready_for_review",
				reason: "PR moved from draft to ready for review",
				reviewPayload,
				context: {
					kind: "ready_for_review",
					triggerSourceId: reviewPayload.headSha || reviewPayload.headRef,
					reason: "PR moved from draft to ready for review",
				},
			});
		}
		if (action === "synchronize") {
			if (isDraft) return draftSkip("draft", "Draft PR synchronized");
			if (!reviewPayload.headSha) {
				return skipClassification({
					eventType,
					action,
					kind: "malformed",
					reason: "Synchronize webhook is missing head SHA",
				});
			}
			return materialClassification({
				eventType,
				action,
				kind: "synchronize",
				reason: `New commit pushed (head ${reviewPayload.headSha.slice(0, 8)})`,
				reviewPayload,
				context: {
					kind: "synchronize",
					triggerSourceId: reviewPayload.headSha,
					reason: `New commit pushed (head ${reviewPayload.headSha.slice(0, 8)})`,
				},
			});
		}
		if (action === "edited") {
			if (isDraft) return draftSkip("draft", "Draft PR edited");
			const changes = payload.changes as Record<string, unknown> | undefined;
			if (!changes) {
				return skipClassification({
					eventType,
					action,
					kind: "metadata_edit",
					relevance: "metadata",
					reason: "PR edited without changed fields",
				});
			}
			const baseChange = changes.base as Record<string, unknown> | undefined;
			if (baseChange !== undefined) {
				// Base-branch retarget materially changes the diff being reviewed,
				// so a new review must be produced. Source ID combines new base ref
				// and head SHA so a webhook retry is deduped but a real retarget
				// still reruns.
				return materialClassification({
					eventType,
					action,
					kind: "base_edit",
					reason: `PR base branch changed to ${reviewPayload.baseRef}`,
					reviewPayload,
					context: {
						kind: "edited",
						triggerSourceId: `base-${reviewPayload.baseRef}-${reviewPayload.headSha}`,
						reason: `PR base branch changed to ${reviewPayload.baseRef}`,
					},
				});
			}
			if (changes.body !== undefined) {
				const bodyHash = createHash("sha256")
					.update(reviewPayload.body)
					.digest("hex")
					.slice(0, 16);
				return materialClassification({
					eventType,
					action,
					kind: "body_edit",
					reason: "PR description edited",
					reviewPayload,
					context: {
						kind: "edited",
						triggerSourceId: `body-${bodyHash}`,
						reason: "PR description edited",
					},
				});
			}
			return skipClassification({
				eventType,
				action,
				kind: "metadata_edit",
				relevance: "metadata",
				reason: "PR metadata edited without body or base changes",
			});
		}
		if (action === "labeled" || action === "unlabeled") {
			return skipClassification({
				eventType,
				action,
				kind: "label",
				relevance: "metadata",
				reason: "PR label metadata changed",
			});
		}
		if (action === "closed") {
			return skipClassification({
				eventType,
				action,
				kind: "closed",
				relevance: "terminal",
				reason: "PR closed",
			});
		}
		return skipClassification({
			eventType,
			action,
			kind: "unsupported",
			reason: `Unsupported pull_request action: ${action}`,
		});
	}

	if (eventType === "issue_comment" && action === "created") {
		const issue = payload.issue as Record<string, unknown> | undefined;
		const comment = payload.comment as Record<string, unknown> | undefined;
		const repoObj = payload.repository as Record<string, unknown> | undefined;
		if (!issue || !comment || !repoObj) {
			return skipClassification({
				eventType,
				action,
				kind: "malformed",
				reason:
					"Issue comment webhook is missing issue, comment, or repository",
			});
		}
		// Only PR comments — issue.pull_request is present on PR threads.
		if (!issue.pull_request) {
			return skipClassification({
				eventType,
				action,
				kind: "unsupported",
				reason: "Issue comment is not on a PR thread",
			});
		}
		const body = String(comment.body ?? "");
		if (!body.trim() || !EVIDENCE_SIGNAL.test(body)) {
			return skipClassification({
				eventType,
				action,
				kind: "non_evidence_comment",
				relevance: "metadata",
				reason: "PR comment does not contain evidence signals",
			});
		}

		const number = Number(issue.number ?? 0);
		if (!number) {
			return skipClassification({
				eventType,
				action,
				kind: "malformed",
				reason: "Issue comment webhook is missing a PR number",
			});
		}
		const prHead = issue.pull_request as Record<string, unknown> | undefined;
		// issue.pull_request from issue_comment payloads carries only URLs; the head
		// SHA is not present, so we accept the empty-SHA case and let the runtime
		// pick up the PR's current head from the API on its own.
		const reviewPayload: PrReviewPayload = {
			number,
			title: String(issue.title ?? ""),
			htmlUrl: String((prHead?.html_url as string) ?? issue.html_url ?? ""),
			body: String(issue.body ?? ""),
			headRef: "",
			headSha: "",
			baseRef: "",
			repoUrl: String(repoObj.html_url ?? ""),
			repoFullName: String(repoObj.full_name ?? ""),
			repoName: String(repoObj.name ?? ""),
		};

		const sender = payload.sender as Record<string, unknown> | undefined;
		const senderLogin = String(sender?.login ?? "unknown");
		const commentId = String(comment.id ?? Date.now());
		return materialClassification({
			eventType,
			action,
			kind: "evidence_comment",
			reason: `Evidence-bearing PR comment by ${senderLogin}`,
			reviewPayload,
			context: {
				kind: "evidence_comment",
				triggerSourceId: `comment-${commentId}`,
				reason: `Evidence-bearing PR comment by ${senderLogin}`,
			},
		});
	}

	if (
		eventType === "pull_request_review_comment" ||
		eventType === "pull_request_review"
	) {
		return skipClassification({
			eventType,
			action,
			kind: "review_comment",
			relevance: "metadata",
			reason: "PR review comments do not change the reviewed head",
		});
	}

	return skipClassification({
		eventType,
		action,
		kind: "unsupported",
		reason: `Unsupported webhook event for managed review: ${eventType}`,
	});
}

export function parsePrReviewTrigger(
	eventType: string,
	action: string,
	payload: Record<string, unknown>,
): ParsedPrTrigger | null {
	const classification = classifyPrReviewTrigger(eventType, action, payload);
	if (classification.decision !== "trigger_review") return null;
	return classification.trigger;
}

// Internal export for tests / future operator paths.
export const __internal = { PR_REVIEWER_BOT_LOGIN, EVIDENCE_SIGNAL };
