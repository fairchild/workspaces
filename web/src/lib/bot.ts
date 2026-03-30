import { createGitHubAdapter } from "@chat-adapter/github";
import { type SlackAdapter, createSlackAdapter } from "@chat-adapter/slack";
import { createMemoryState } from "@chat-adapter/state-memory";
import { Chat, toAiMessages } from "chat";
import type { Message, Thread } from "chat";
import { isAiConfigured, streamResponse } from "./ai";
import { getEventStats } from "./events";
import { formatWorkspaceStatusCard, getWorkspaces } from "./workspaces";

let _bot: Chat | undefined;

function buildAdapters(): Record<
	string,
	ReturnType<typeof createGitHubAdapter> | SlackAdapter
> {
	const appId = process.env.GITHUB_WEB_WORKSPACES_APP_ID ?? "";
	const privateKey = (
		process.env.GITHUB_WEB_WORKSPACES_PRIVATE_KEY ?? ""
	).replace(/\\n/g, "\n");

	const adapters: Record<
		string,
		ReturnType<typeof createGitHubAdapter> | SlackAdapter
	> = {
		github: createGitHubAdapter({
			appId,
			privateKey,
			webhookSecret: process.env.GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET,
		}),
	};

	if (process.env.SLACK_BOT_TOKEN) {
		adapters.slack = createSlackAdapter({
			botToken: process.env.SLACK_BOT_TOKEN,
			signingSecret: process.env.SLACK_SIGNING_SECRET,
		});
	}

	return adapters;
}

export function getBot(): Chat {
	if (!_bot) {
		_bot = new Chat({
			userName: process.env.CHAT_BOT_USERNAME ?? "spaces-bot",
			adapters: buildAdapters(),
			state: createMemoryState(),
			fallbackStreamingPlaceholderText: null,
			streamingUpdateIntervalMs: 1000,
		});

		_bot.onNewMessage(/status/i, async (thread) => {
			const [stats, workspaces] = await Promise.all([
				getEventStats(),
				getWorkspaces("default"),
			]);
			const repoList =
				stats.repos.length > 0
					? stats.repos.map((r) => `- ${r}`).join("\n")
					: "No repos tracked yet.";
			const card = formatWorkspaceStatusCard(workspaces);
			await thread.post(
				`**Active repos:**\n${repoList}\n\nEvents today: ${stats.eventsToday}\n\n${card}`,
			);
		});

		_bot.onNewMention(async (thread, message) => {
			await handleAiResponse(thread, message);
			await thread.subscribe();
		});

		_bot.onSubscribedMessage(async (thread, message) => {
			await handleAiResponse(thread, message);
		});
	}
	return _bot;
}

async function handleAiResponse(
	thread: Thread,
	message: Message,
): Promise<void> {
	if (!isAiConfigured()) {
		const [stats, workspaces] = await Promise.all([
			getEventStats(),
			getWorkspaces("default"),
		]);
		const card = formatWorkspaceStatusCard(workspaces);
		await thread.post(
			`Tracking ${stats.repos.length} repo(s) with ${stats.eventsToday} event(s) today.\n\n${card}`,
		);
		return;
	}

	await thread.refresh();
	const history = await toAiMessages(thread.recentMessages, {
		includeNames: true,
	});

	if (history.length === 0) {
		history.push({ role: "user", content: message.text });
	}

	const stream = streamResponse(history);
	await thread.post(stream);
}

export function getSlackAdapter(): SlackAdapter | null {
	const bot = getBot();
	try {
		return bot.getAdapter("slack") as SlackAdapter;
	} catch {
		return null;
	}
}
