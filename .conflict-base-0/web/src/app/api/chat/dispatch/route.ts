import crypto from "node:crypto";
import { getSession } from "@/lib/auth-server";
import { pushChatMessage } from "@/lib/chat";
import { formatDispatchBody, parseIssueRef } from "@/lib/chat-utils";
import { createDiscussion, getGitHubToken } from "@/lib/github";
import { getUserRepos } from "@/lib/repos";
import type { ChatMessage, DispatchMetadata } from "@/lib/types";

export const dynamic = "force-dynamic";

interface DispatchBody {
	repo: string;
	agentName: string;
	task: string;
	issueRef?: string;
}

export async function POST(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session?.user) {
		return Response.json({ error: "unauthorized" }, { status: 401 });
	}

	const body = (await request.json()) as DispatchBody;
	if (!body.repo || !body.agentName || !body.task) {
		return Response.json(
			{ error: "repo, agentName, and task are required" },
			{ status: 400 },
		);
	}

	const [owner, repo] = body.repo.split("/");
	if (!owner || !repo) {
		return Response.json(
			{ error: "repo must be owner/name format" },
			{ status: 400 },
		);
	}

	const userRepos = await getUserRepos(session.user.id);
	if (!userRepos.some((r) => `${r.owner}/${r.repo}` === body.repo)) {
		return Response.json(
			{ error: "repo not in your workspace" },
			{ status: 403 },
		);
	}

	let token: string;
	if (process.env.DEV_BYPASS_AUTH === "1") {
		token = "dev-bypass-token";
	} else {
		const ghToken = await getGitHubToken(session.user.id);
		if (!ghToken) {
			return Response.json(
				{ error: "GitHub token not found" },
				{ status: 403 },
			);
		}
		token = ghToken;
	}

	const taskId = crypto.randomUUID().slice(0, 8);
	const timestamp = new Date().toISOString();
	const issueRef = body.issueRef ?? parseIssueRef(body.task);

	const title = `@${body.agentName}: ${body.task.slice(0, 100)}`;
	const discussionBody = formatDispatchBody(
		body.agentName,
		body.task,
		issueRef,
		taskId,
	);

	let discussionId: string | null = null;
	let discussionUrl: string | null = null;

	try {
		const discussion = await createDiscussion(
			token,
			owner,
			repo,
			title,
			discussionBody,
		);
		discussionId = discussion.id;
		discussionUrl = discussion.url;
	} catch (err) {
		console.error("[dispatch] GitHub Discussion error:", err);
		return Response.json(
			{ error: "Failed to create GitHub Discussion" },
			{ status: 502 },
		);
	}

	const userMessageId = crypto.randomUUID();
	const userMessage: ChatMessage = {
		id: userMessageId,
		repo: body.repo,
		author: session.user.name ?? session.user.email ?? "you",
		authorType: "user",
		content: `@${body.agentName} ${body.task}`,
		agentTarget: body.agentName,
		discussionId,
		discussionUrl,
		timestamp,
	};
	await pushChatMessage(userMessage);

	const dispatchMetadata: DispatchMetadata = {
		type: "dispatch",
		taskId,
		agent: body.agentName,
		task: body.task,
		issueRef,
		repo: body.repo,
		discussionUrl: discussionUrl ?? "",
		status: "pending",
		branch: null,
		prUrl: null,
	};

	const botMessageId = crypto.randomUUID();
	const botMessage: ChatMessage = {
		id: botMessageId,
		repo: body.repo,
		author: "spaces-bot",
		authorType: "bot",
		content: JSON.stringify(dispatchMetadata),
		agentTarget: body.agentName,
		discussionId,
		discussionUrl,
		timestamp: new Date(Date.now() + 1).toISOString(),
	};
	await pushChatMessage(botMessage);

	return Response.json({
		taskId,
		messageId: userMessageId,
		discussionId,
		discussionUrl,
	});
}
