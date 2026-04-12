import crypto from "node:crypto";
import {
	ALLOWED_AGENT_LOGINS,
	DEFAULT_AGENT,
} from "@/lib/agent-runtime/config";
import { resolvePersona } from "@/lib/agent-runtime/persona-loader";
import { authorizeRepoAccess, unauthorizedResponse } from "@/lib/api-auth";
import { getDevBypassToken, getSession } from "@/lib/auth-server";
import { getMixedTimeline, pushChatMessage } from "@/lib/chat";
import { handleBotCommand, parseAgentMention } from "@/lib/chat-utils";
import { getEventStats } from "@/lib/events";
import {
	addDiscussionComment,
	createDiscussion,
	fetchGitHubLogin,
	getGitHubToken,
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
	if (!session?.user) return unauthorizedResponse();

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

	const unauthorized = await authorizeRepoAccess(session.user.id, body.repo);
	if (unauthorized) return unauthorized;

	let token: string | null;
	const bypassToken = getDevBypassToken();
	if (bypassToken) {
		token = bypassToken;
	} else {
		token = await getGitHubToken(session.user.id);
		if (!token) {
			return Response.json(
				{ error: "GitHub token not found" },
				{ status: 403 },
			);
		}
	}

	const messageId = crypto.randomUUID();
	const timestamp = new Date().toISOString();
	let discussionId: string | null = null;
	let discussionUrl: string | null = null;

	const explicitTarget = body.agentName ?? parseAgentMention(body.message);
	const agentTarget = explicitTarget ?? DEFAULT_AGENT;

	// Bot commands only for explicit @mentions (not default agent fallback)
	const botResponse = await handleBotCommand({
		target: explicitTarget,
		message: body.message,
		repo: body.repo,
		author: session.user.name ?? session.user.email ?? "you",
		getEventStats,
		pushChatMessage,
	});
	if (botResponse) {
		return Response.json(botResponse);
	}

	// Check if the mention targets a known agent persona (restricted to allowed users).
	if (agentTarget && agentTarget !== "spaces") {
		const login = getDevBypassToken()
			? "fairchild"
			: await fetchGitHubLogin(token);
		if (ALLOWED_AGENT_LOGINS.has(login)) {
			const persona = await resolvePersona(token, owner, repo, agentTarget);
			if (persona) {
				const chatMessage: ChatMessage = {
					id: messageId,
					repo: body.repo,
					author: session.user.name ?? session.user.email ?? "you",
					authorType: "user",
					content: body.message,
					agentTarget,
					discussionId: null,
					discussionUrl: null,
					timestamp,
				};
				await pushChatMessage(chatMessage);

				return Response.json({
					messageId,
					agentSession: {
						agentName: agentTarget,
						streamUrl: "/api/chat/agent-stream",
						threadId: body.parentDiscussionId ?? messageId,
					},
				});
			}
			// Persona not found — fall through to Discussion creation
		}
	}

	// Use explicit target (not default fallback) for Discussion titles
	const effectiveTarget = explicitTarget;
	const title = effectiveTarget
		? `@${effectiveTarget}: ${body.message.slice(0, 100)}`
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
		agentTarget: effectiveTarget ?? null,
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
	if (!session?.user) return unauthorizedResponse();

	const { searchParams } = new URL(request.url);
	const repo = searchParams.get("repo");
	if (!repo) {
		return Response.json(
			{ error: "repo query parameter is required" },
			{ status: 400 },
		);
	}

	const unauthorized = await authorizeRepoAccess(session.user.id, repo);
	if (unauthorized) return unauthorized;

	const limit = Math.min(Number(searchParams.get("limit") ?? 50), 200);
	const since = searchParams.get("since") ?? undefined;

	const timeline = await getMixedTimeline(repo, limit, since);
	return Response.json(timeline);
}
