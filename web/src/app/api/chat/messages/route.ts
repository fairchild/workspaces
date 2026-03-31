import crypto from "node:crypto";
import { ALLOWED_AGENT_LOGINS } from "@/lib/agent-runtime/config";
import { resolvePersona } from "@/lib/agent-runtime/persona-loader";
import { getSession } from "@/lib/auth-server";
import { getMixedTimeline, pushChatMessage } from "@/lib/chat";
import { parseAgentMention, stripMention } from "@/lib/chat-utils";
import { getEventStats } from "@/lib/events";
import {
	addDiscussionComment,
	createDiscussion,
	fetchGitHubLogin,
	getGitHubToken,
} from "@/lib/github";
import { getUserRepos } from "@/lib/repos";
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

	const userRepos = await getUserRepos(session.user.id);
	if (!userRepos.some((r) => `${r.owner}/${r.repo}` === body.repo)) {
		return Response.json(
			{ error: "repo not in your workspace" },
			{ status: 403 },
		);
	}

	const token = await getGitHubToken(session.user.id);
	if (!token) {
		return Response.json({ error: "GitHub token not found" }, { status: 403 });
	}

	const messageId = crypto.randomUUID();
	const timestamp = new Date().toISOString();
	let discussionId: string | null = null;
	let discussionUrl: string | null = null;

	const agentTarget = body.agentName ?? parseAgentMention(body.message);

	// Bot commands: @spaces status, @spaces pipeline, @<agent> status
	const botResponse = await handleBotCommand(
		agentTarget,
		body.message,
		body.repo,
		session.user.name ?? session.user.email ?? "you",
	);
	if (botResponse) {
		return Response.json(botResponse);
	}

	// Check if the mention targets a known agent persona (restricted to allowed users).
	if (agentTarget && agentTarget !== "spaces") {
		const login = await fetchGitHubLogin(token);
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

async function handleBotCommand(
	target: string | null,
	message: string,
	repo: string,
	author: string,
): Promise<{ messageId: string; botMessageId: string } | null> {
	if (!target) return null;
	const command = stripMention(message).toLowerCase();

	let responseContent: string | null = null;

	if (target === "spaces" && /^status$/i.test(command)) {
		const stats = await getEventStats();
		const repoList =
			stats.repos.length > 0
				? stats.repos.map((r) => `- ${r}`).join("\n")
				: "No repos tracked yet.";
		responseContent = `**Active repos:**\n${repoList}\n\nEvents today: ${stats.eventsToday}`;
	} else if (target === "spaces" && /^pipeline$/i.test(command)) {
		responseContent =
			"Pipeline summary is available on the Dashboard tab. Select a repo to view its issue pipeline.";
	} else if (target !== "spaces" && /^status$/i.test(command)) {
		responseContent = `Checking status for **@${target}**... No active dispatches found. Use \`@${target} <task>\` to dispatch work.`;
	} else {
		return null;
	}

	const timestamp = new Date().toISOString();

	const userMsg: ChatMessage = {
		id: crypto.randomUUID(),
		repo,
		author,
		authorType: "user",
		content: message,
		agentTarget: target,
		discussionId: null,
		discussionUrl: null,
		timestamp,
	};
	await pushChatMessage(userMsg);

	const botMsg: ChatMessage = {
		id: crypto.randomUUID(),
		repo,
		author: "spaces-bot",
		authorType: "bot",
		content: responseContent,
		agentTarget: null,
		discussionId: null,
		discussionUrl: null,
		timestamp: new Date(Date.now() + 1).toISOString(),
	};
	await pushChatMessage(botMsg);

	return { messageId: userMsg.id, botMessageId: botMsg.id };
}
