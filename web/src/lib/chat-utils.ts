import crypto from "node:crypto";
import type { EventStats } from "./events";
import type { ChatMessage } from "./types";

const FORBIDDEN_PUBLIC_AGENT_MENTION_RE =
	/(^|[^A-Za-z0-9_-])@(april)(?![A-Za-z0-9_-])/i;
const PUBLIC_AGENT_TARGET_RE = /^[A-Za-z0-9][A-Za-z0-9_-]*$/;

export function findForbiddenPublicAgentMention(text: string): string | null {
	const match = text.match(FORBIDDEN_PUBLIC_AGENT_MENTION_RE);
	return match ? `@${match[2]}` : null;
}

export function validatePublicAgentTarget(
	target: string | null | undefined,
	options: { allowSpaces?: boolean } = {},
): string | null {
	if (!target) return null;
	if (!PUBLIC_AGENT_TARGET_RE.test(target)) {
		return "Agent names may contain only letters, numbers, underscores, and hyphens.";
	}
	if (target.toLowerCase() === "spaces") {
		return options.allowSpaces === false
			? "@spaces is a bot command target, not a dispatchable agent."
			: null;
	}
	if (target.toLowerCase() === "april") {
		return "Use @april-clearwater instead of @april; @april is a different GitHub user.";
	}
	return null;
}

export async function handleBotCommand(params: {
	target: string | null;
	message: string;
	repo: string;
	author: string;
	getEventStats: () => Promise<EventStats>;
	pushChatMessage: (msg: ChatMessage) => Promise<void>;
}): Promise<{ messageId: string; botMessageId: string } | null> {
	const { target, message, repo, author } = params;
	if (!target) return null;
	const command = stripMention(message).toLowerCase();

	let responseContent: string | null = null;

	if (target === "spaces" && /^status$/i.test(command)) {
		const stats = await params.getEventStats();
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
	await params.pushChatMessage(userMsg);

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
	await params.pushChatMessage(botMsg);

	return { messageId: userMsg.id, botMessageId: botMsg.id };
}

export function parseAgentMention(message: string): string | null {
	const match = message.match(/^@(\w[\w-]*)/);
	return match ? match[1] : null;
}

export function stripMention(message: string): string {
	return message.replace(/^@\w[\w-]*\s*/, "").trim();
}

export function parseIssueRef(task: string): string | null {
	const match = task.match(/#(\d+)/);
	return match ? `#${match[1]}` : null;
}

export function formatDispatchBody(
	agent: string,
	task: string,
	issueRef: string | null,
	taskId: string,
): string {
	const lines = [
		`**Agent:** @${agent}`,
		`**Task:** ${task}`,
		`**Task ID:** \`${taskId}\``,
	];
	if (issueRef) {
		lines.push(`**Issue:** ${issueRef}`);
	}
	lines.push(
		"",
		"---",
		"*Dispatched from [Spaces](https://spaces.cloudcompute.com) chat*",
	);
	return lines.join("\n");
}
