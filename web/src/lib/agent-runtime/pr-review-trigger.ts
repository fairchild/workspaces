import { createHash } from "node:crypto";
import type { PrReviewPayload, PrReviewTrigger } from "./pr-review";

export interface ParsedPrTrigger {
	reviewPayload: PrReviewPayload;
	context: PrReviewTrigger;
}

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

export function parsePrReviewTrigger(
	eventType: string,
	action: string,
	payload: Record<string, unknown>,
): ParsedPrTrigger | null {
	if (isBotSender(payload)) return null;

	if (eventType === "pull_request") {
		const pr = payload.pull_request as Record<string, unknown> | undefined;
		const repoObj = payload.repository as Record<string, unknown> | undefined;
		if (!pr || !repoObj) return null;
		const reviewPayload = buildReviewPayloadFromPr(pr, repoObj);
		if (!reviewPayload) return null;

		const isDraft = Boolean(pr.draft);

		if (action === "opened") {
			if (isDraft) return null;
			return {
				reviewPayload,
				context: {
					kind: "opened",
					triggerSourceId: reviewPayload.headSha || reviewPayload.headRef,
					reason: "PR opened",
				},
			};
		}
		if (action === "reopened") {
			if (isDraft) return null;
			return {
				reviewPayload,
				context: {
					kind: "reopened",
					triggerSourceId: reviewPayload.headSha || reviewPayload.headRef,
					reason: "PR reopened",
				},
			};
		}
		if (action === "ready_for_review") {
			return {
				reviewPayload,
				context: {
					kind: "ready_for_review",
					triggerSourceId: reviewPayload.headSha || reviewPayload.headRef,
					reason: "PR moved from draft to ready for review",
				},
			};
		}
		if (action === "synchronize") {
			if (isDraft) return null;
			if (!reviewPayload.headSha) return null;
			return {
				reviewPayload,
				context: {
					kind: "synchronize",
					triggerSourceId: reviewPayload.headSha,
					reason: `New commit pushed (head ${reviewPayload.headSha.slice(0, 8)})`,
				},
			};
		}
		if (action === "edited") {
			if (isDraft) return null;
			const changes = payload.changes as Record<string, unknown> | undefined;
			if (!changes || changes.body === undefined) return null;
			const bodyHash = createHash("sha256")
				.update(reviewPayload.body)
				.digest("hex")
				.slice(0, 16);
			return {
				reviewPayload,
				context: {
					kind: "edited",
					triggerSourceId: `body-${bodyHash}`,
					reason: "PR description edited",
				},
			};
		}
		return null;
	}

	if (eventType === "issue_comment" && action === "created") {
		const issue = payload.issue as Record<string, unknown> | undefined;
		const comment = payload.comment as Record<string, unknown> | undefined;
		const repoObj = payload.repository as Record<string, unknown> | undefined;
		if (!issue || !comment || !repoObj) return null;
		// Only PR comments — issue.pull_request is present on PR threads.
		if (!issue.pull_request) return null;
		const body = String(comment.body ?? "");
		if (!body.trim()) return null;
		if (!EVIDENCE_SIGNAL.test(body)) return null;

		const number = Number(issue.number ?? 0);
		if (!number) return null;
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
		return {
			reviewPayload,
			context: {
				kind: "evidence_comment",
				triggerSourceId: `comment-${commentId}`,
				reason: `Evidence-bearing PR comment by ${senderLogin}`,
			},
		};
	}

	return null;
}

// Internal export for tests / future operator paths.
export const __internal = { PR_REVIEWER_BOT_LOGIN, EVIDENCE_SIGNAL };
