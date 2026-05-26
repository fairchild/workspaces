import crypto from "node:crypto";
import {
	ALLOWED_AGENT_LOGINS,
	DEFAULT_AGENT,
} from "@/lib/agent-runtime/config";
import { resolvePersona } from "@/lib/agent-runtime/persona-loader";
import { authorizeRepoAccess, unauthorizedResponse } from "@/lib/api-auth";
import { getDevBypassToken, getSession } from "@/lib/auth-server";
import { getMixedTimeline, pushChatMessage } from "@/lib/chat";
import {
	findForbiddenPublicAgentMention,
	handleBotCommand,
	parseAgentMention,
	validatePublicAgentTarget,
} from "@/lib/chat-utils";
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
	// Explicit targets become GitHub @mentions in Discussion titles, so reject
	// unsafe aliases before publishing user text to a public repo.
	const targetError = validatePublicAgentTarget(explicitTarget, {
		allowSpaces: true,
	});
	if (targetError) {
		return Response.json({ error: targetError }, { status: 400 });
	}
	const forbiddenMention = findForbiddenPublicAgentMention(body.message);
	if (forbiddenMention) {
		return Response.json(
			{
				error: `Use @april-clearwater instead of ${forbiddenMention}; @april is a different GitHub user.`,
			},
			{ status: 400 },
		);
	}
	const agentTarget = explicitTarget ?? DEFAULT_AGENT;
	let resolvedExplicitPersona = false;

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
		const persona = await resolvePersona(token, owner, repo, agentTarget);
		resolvedExplicitPersona = explicitTarget !== null && persona !== null;
		const login = getDevBypassToken()
			? "fairchild"
			: await fetchGitHubLogin(token);
		if (persona && ALLOWED_AGENT_LOGINS.has(login)) {
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
	}

	// Use explicit target (not default fallback) for Discussion titles
	const effectiveTarget = explicitTarget;
	if (
		effectiveTarget &&
		effectiveTarget !== "spaces" &&
		!resolvedExplicitPersona
	) {
		return Response.json(
			{
				error:
					"Unknown agent target. Use a discovered repo persona such as @april-clearwater.",
			},
			{ status: 400 },
		);
	}
	if (effectiveTarget === "spaces") {
		return Response.json(
			{ error: "Unknown @spaces command." },
			{ status: 400 },
		);
	}
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
