import { createGitHubAdapter } from "@chat-adapter/github";
import { createMemoryState } from "@chat-adapter/state-memory";
import { Chat, toAiMessages } from "chat";
import type { Message, Thread } from "chat";
import { isAiConfigured, streamResponse } from "./ai";
import { getEventStats } from "./events";

let _bot: Chat | undefined;

export function getBot(): Chat {
	if (!_bot) {
		const appId = process.env.GITHUB_APP_ID ?? "";
		const privateKey = (process.env.GITHUB_PRIVATE_KEY ?? "").replace(
			/\\n/g,
			"\n",
		);

		_bot = new Chat({
			userName: process.env.CHAT_BOT_USERNAME ?? "spaces-bot",
			adapters: {
				github: createGitHubAdapter({
					appId,
					privateKey,
					webhookSecret: process.env.GITHUB_WEBHOOK_SECRET,
				}),
			},
			state: createMemoryState(),
			fallbackStreamingPlaceholderText: null,
			streamingUpdateIntervalMs: 1000,
		});

		_bot.onNewMessage(/^!status$/i, async (thread) => {
			const stats = await getEventStats();
			const repoList =
				stats.repos.length > 0
					? stats.repos.map((r) => `- ${r}`).join("\n")
					: "No repos tracked yet.";
			await thread.post(
				`**Active repos:**\n${repoList}\n\nEvents today: ${stats.eventsToday}`,
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
		const stats = await getEventStats();
		await thread.post(
			`Tracking ${stats.repos.length} repo(s) with ${stats.eventsToday} event(s) today.`,
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
