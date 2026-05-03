import crypto from "node:crypto";
import {
	type PrReviewPayload,
	triggerPrReview,
} from "@/lib/agent-runtime/pr-review";
import {
	getChatMessageByDiscussionId,
	pushChatMessage,
	updateChatMessageContent,
} from "@/lib/chat";
import { pushEvent } from "@/lib/events";
import type {
	ChatMessage,
	DispatchMetadata,
	WebhookEvent,
	WebhookEventType,
} from "@/lib/types";

export const dynamic = "force-dynamic";

const SUPPORTED_EVENTS = new Set<string>([
	"pull_request",
	"check_run",
	"check_suite",
	"discussion",
	"discussion_comment",
	"push",
	"issues",
	"issue_comment",
	"workflow_run",
]);

async function verifySignature(
	body: string,
	signature: string | null,
): Promise<boolean> {
	const secret = process.env.GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET;
	if (!secret) {
		if (process.env.NODE_ENV === "production") {
			console.warn("[webhooks] WEBHOOK_SECRET is not set — rejecting");
			return false;
		}
		return true;
	}
	if (!signature) {
		console.warn("[webhooks] no signature header");
		return false;
	}

	const expected = `sha256=${crypto.createHmac("sha256", secret).update(body).digest("hex")}`;

	if (signature.length !== expected.length) {
		console.warn(
			`[webhooks] sig length mismatch: got=${signature.length} expected=${expected.length} secret_len=${secret.length}`,
		);
		return false;
	}

	const sigBuf = Buffer.from(signature);
	const expectedBuf = Buffer.from(expected);
	return crypto.timingSafeEqual(sigBuf, expectedBuf);
}

function summarize(
	type: string,
	action: string,
	payload: Record<string, unknown>,
): string {
	switch (type) {
		case "pull_request": {
			const pr = payload.pull_request as Record<string, unknown> | undefined;
			return `${action} #${pr?.number ?? "?"}: ${pr?.title ?? ""}`;
		}
		case "push": {
			const commits = payload.commits as unknown[] | undefined;
			const ref = String(payload.ref ?? "").replace("refs/heads/", "");
			return `${commits?.length ?? 0} commit(s) to ${ref}`;
		}
		case "issues": {
			const issue = payload.issue as Record<string, unknown> | undefined;
			return `${action} #${issue?.number ?? "?"}: ${issue?.title ?? ""}`;
		}
		case "check_run": {
			const cr = payload.check_run as Record<string, unknown> | undefined;
			return `${cr?.name ?? "check"}: ${cr?.conclusion ?? action}`;
		}
		case "workflow_run": {
			const wr = payload.workflow_run as Record<string, unknown> | undefined;
			return `${wr?.name ?? "workflow"}: ${wr?.conclusion ?? action}`;
		}
		default:
			return action;
	}
}

export async function POST(request: Request): Promise<Response> {
	const body = await request.text();
	const signature = request.headers.get("x-hub-signature-256");

	if (!(await verifySignature(body, signature))) {
		return new Response("invalid signature", { status: 401 });
	}

	const eventType = request.headers.get("x-github-event");
	if (!eventType || !SUPPORTED_EVENTS.has(eventType)) {
		return new Response("ignored", { status: 200 });
	}

	const payload = JSON.parse(body) as Record<string, unknown>;
	const action = String(payload.action ?? "");
	const repo = (payload.repository as Record<string, unknown> | undefined)
		?.full_name as string | undefined;

	const event: WebhookEvent = {
		id: request.headers.get("x-github-delivery") ?? crypto.randomUUID(),
		type: eventType as WebhookEventType,
		action,
		summary: summarize(eventType, action, payload),
		repo: repo ?? "unknown",
		timestamp: new Date().toISOString(),
		payload: body,
	};

	await pushEvent(event);

	// Bridge discussion/discussion_comment webhooks into chat_messages
	if (eventType === "discussion" || eventType === "discussion_comment") {
		const chatMsg = extractDiscussionChatMessage(
			eventType,
			payload,
			repo ?? "unknown",
		);
		if (chatMsg) {
			await pushChatMessage(chatMsg);
		}
	}

	// Update dispatch cards when PR/CI events link back to a Discussion
	if (
		eventType === "pull_request" ||
		eventType === "check_run" ||
		eventType === "workflow_run"
	) {
		await updateDispatchFromWebhook(eventType, action, payload);
	}

	// Trigger automated PR review via Managed Agents before returning so
	// serverless teardown cannot drop the session kickoff event.
	if (eventType === "pull_request" && action === "opened") {
		const pr = payload.pull_request as Record<string, unknown> | undefined;
		const repoObj = payload.repository as Record<string, unknown> | undefined;
		if (pr && repoObj) {
			const head = pr.head as Record<string, unknown> | undefined;
			const base = pr.base as Record<string, unknown> | undefined;
			const reviewPayload: PrReviewPayload = {
				number: Number(pr.number ?? 0),
				title: String(pr.title ?? ""),
				htmlUrl: String(pr.html_url ?? ""),
				headRef: String(head?.ref ?? ""),
				baseRef: String(base?.ref ?? ""),
				repoUrl: String(repoObj.html_url ?? ""),
				repoFullName: String(repoObj.full_name ?? ""),
				repoName: String(repoObj.name ?? ""),
			};
			try {
				await triggerPrReview(reviewPayload);
			} catch (err) {
				console.error("[pr-review] failed:", err);
			}
		}
	}

	return Response.json({ ok: true });
}

function extractDiscussionChatMessage(
	eventType: string,
	payload: Record<string, unknown>,
	repo: string,
): ChatMessage | null {
	if (eventType === "discussion_comment") {
		const comment = payload.comment as Record<string, unknown> | undefined;
		const discussion = payload.discussion as
			| Record<string, unknown>
			| undefined;
		if (!comment?.body) return null;
		const user = comment.user as Record<string, unknown> | undefined;
		const isBot = String(user?.type ?? "").toLowerCase() === "bot";
		return {
			id: `ghdc-${comment.id ?? crypto.randomUUID()}`,
			repo,
			author: String(user?.login ?? "unknown"),
			authorType: isBot ? "bot" : "user",
			content: String(comment.body),
			agentTarget: null,
			discussionId: String(discussion?.node_id ?? ""),
			discussionUrl: String(comment.html_url ?? discussion?.html_url ?? ""),
			timestamp: String(comment.created_at ?? new Date().toISOString()),
		};
	}

	if (eventType === "discussion") {
		const discussion = payload.discussion as
			| Record<string, unknown>
			| undefined;
		const action = String(payload.action ?? "");
		if (action !== "created" || !discussion?.body) return null;
		const user = discussion.user as Record<string, unknown> | undefined;
		const isBot = String(user?.type ?? "").toLowerCase() === "bot";
		return {
			id: `ghd-${discussion.id ?? crypto.randomUUID()}`,
			repo,
			author: String(user?.login ?? "unknown"),
			authorType: isBot ? "bot" : "user",
			content: String(discussion.body),
			agentTarget: null,
			discussionId: String(discussion.node_id ?? ""),
			discussionUrl: String(discussion.html_url ?? ""),
			timestamp: String(discussion.created_at ?? new Date().toISOString()),
		};
	}

	return null;
}

function parseDispatchMetadata(content: string): DispatchMetadata | null {
	try {
		const parsed = JSON.parse(content);
		if (parsed?.type === "dispatch") return parsed as DispatchMetadata;
	} catch {
		// Not JSON or not dispatch metadata
	}
	return null;
}

function extractDiscussionUrlFromBody(body: string): string | null {
	// Match GitHub Discussion URLs in PR body
	const match = body.match(
		/https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/discussions\/\d+/,
	);
	return match ? match[0] : null;
}

async function updateDispatchFromWebhook(
	eventType: string,
	action: string,
	payload: Record<string, unknown>,
): Promise<void> {
	try {
		if (eventType === "pull_request") {
			const pr = payload.pull_request as Record<string, unknown> | undefined;
			if (!pr?.body) return;

			const discussionUrl = extractDiscussionUrlFromBody(String(pr.body));
			if (!discussionUrl) return;

			// Find the dispatch card by searching for a bot message linking to this Discussion
			const nodeId = pr.node_id as string | undefined;
			// We need the discussion node_id, but we have the URL. Search by content.
			// Instead, find the bot message whose content JSON references this Discussion URL.
			const { getDb } = await import("@/lib/db");
			const db = getDb();
			const rows = await db
				.selectFrom("chat_messages")
				.select(["id", "content"])
				.where("author_type", "=", "bot")
				.where("content", "like", "%dispatch%")
				.orderBy("timestamp", "desc")
				.limit(50)
				.execute();

			for (const row of rows) {
				const meta = parseDispatchMetadata(row.content);
				if (!meta || !meta.discussionUrl) continue;
				if (
					!discussionUrl.includes(meta.discussionUrl) &&
					!meta.discussionUrl.includes(discussionUrl)
				)
					continue;

				const updated: DispatchMetadata = {
					...meta,
					status:
						action === "closed" && (pr.merged as boolean)
							? "complete"
							: "pr_opened",
					branch: String(
						(pr.head && (pr.head as Record<string, unknown>).ref) ||
							meta.branch ||
							"",
					),
					prUrl: String(pr.html_url ?? meta.prUrl ?? ""),
				};
				await updateChatMessageContent(row.id, JSON.stringify(updated));
				return;
			}
		}

		if (eventType === "check_run" || eventType === "workflow_run") {
			const run = (payload.check_run ?? payload.workflow_run) as
				| Record<string, unknown>
				| undefined;
			if (!run) return;
			const conclusion = String(run.conclusion ?? "");
			if (!conclusion) return;

			const prs = run.pull_requests as
				| Array<Record<string, unknown>>
				| undefined;
			if (!prs?.length) return;

			const prUrl = String(prs[0].url ?? "").replace(
				"api.github.com/repos",
				"github.com",
			);

			const { getDb } = await import("@/lib/db");
			const db = getDb();
			const rows = await db
				.selectFrom("chat_messages")
				.select(["id", "content"])
				.where("author_type", "=", "bot")
				.where("content", "like", "%dispatch%")
				.orderBy("timestamp", "desc")
				.limit(50)
				.execute();

			for (const row of rows) {
				const meta = parseDispatchMetadata(row.content);
				if (!meta?.prUrl) continue;
				if (
					!meta.prUrl.includes(String(prs[0].number ?? "")) &&
					prUrl !== meta.prUrl
				)
					continue;
				if (meta.status === "complete" || meta.status === "failed") continue;

				const updated: DispatchMetadata = {
					...meta,
					status:
						conclusion === "success"
							? "ci_passed"
							: conclusion === "failure"
								? "failed"
								: meta.status,
				};
				await updateChatMessageContent(row.id, JSON.stringify(updated));
				return;
			}
		}
	} catch (err) {
		console.error("[webhooks] dispatch update error:", err);
	}
}
