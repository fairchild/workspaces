import crypto from "node:crypto";
import { pushChatMessage, getMixedTimeline } from "@/lib/chat";
import { getSession } from "@/lib/auth-server";
import {
	getGitHubToken,
	createDiscussion,
	addDiscussionComment,
} from "@/lib/github";
import type { ChatMessage } from "@/lib/types";

export const dynamic = "force-dynamic";

interface PostBody {
	repo: string;
	agentName?: string;
	message: string;
	parentDiscussionId?: string;
}

export async function POST(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session?.user) {
		return Response.json({ error: "unauthorized" }, { status: 401 });
	}

	const body = (await request.json()) as PostBody;
	if (!body.repo || !body.message) {
		return Response.json(
			{ error: "repo and message are required" },
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

	const token = await getGitHubToken(session.user.id);
	if (!token) {
		return Response.json(
			{ error: "GitHub token not found" },
			{ status: 403 },
		);
	}

	const messageId = crypto.randomUUID();
	const timestamp = new Date().toISOString();
	let discussionId: string | null = null;
	let discussionUrl: string | null = null;

	const agentTarget = body.agentName ?? parseAgentMention(body.message);
	const title = agentTarget
		? `@${agentTarget}: ${body.message.slice(0, 100)}`
		: body.message.slice(0, 100);

	try {
		if (body.parentDiscussionId) {
			const comment = await addDiscussionComment(
				token,
				body.parentDiscussionId,
				body.message,
			);
			discussionId = body.parentDiscussionId;
			discussionUrl = comment.url;
		} else {
			const discussion = await createDiscussion(
				token,
				owner,
				repo,
				title,
				body.message,
			);
			discussionId = discussion.id;
			discussionUrl = discussion.url;
		}
	} catch (err) {
		console.error("[chat] GitHub Discussion error:", err);
		// Still persist the chat message even if Discussion creation fails
	}

	const chatMessage: ChatMessage = {
		id: messageId,
		repo: body.repo,
		author: session.user.name ?? session.user.email ?? "you",
		authorType: "user",
		content: body.message,
		agentTarget: agentTarget ?? null,
		discussionId,
		discussionUrl,
		timestamp,
	};

	await pushChatMessage(chatMessage);

	return Response.json({
		messageId,
		discussionId,
		discussionUrl,
	});
}

export async function GET(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session?.user) {
		return Response.json({ error: "unauthorized" }, { status: 401 });
	}

	const { searchParams } = new URL(request.url);
	const repo = searchParams.get("repo");
	if (!repo) {
		return Response.json(
			{ error: "repo query parameter is required" },
			{ status: 400 },
		);
	}

	const limit = Math.min(Number(searchParams.get("limit") ?? 50), 200);
	const since = searchParams.get("since") ?? undefined;

	const timeline = await getMixedTimeline(repo, limit, since);
	return Response.json(timeline);
}

function parseAgentMention(message: string): string | null {
	const match = message.match(/^@(\w[\w-]*)/);
	return match ? match[1] : null;
}
