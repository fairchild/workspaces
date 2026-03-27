import { createGitHubAdapter } from "@chat-adapter/github";
import { createMemoryState } from "@chat-adapter/state-memory";
import { Chat } from "chat";
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
		});

		_bot.onNewMention(async (thread) => {
			const stats = await getEventStats();
			await thread.post(
				`Tracking ${stats.repos.length} repo(s) with ${stats.eventsToday} event(s) today.`,
			);
		});

		_bot.onNewMessage(/status/i, async (thread) => {
			const stats = await getEventStats();
			const repoList =
				stats.repos.length > 0
					? stats.repos.map((r) => `- ${r}`).join("\n")
					: "No repos tracked yet.";
			await thread.post(
				`**Active repos:**\n${repoList}\n\nEvents today: ${stats.eventsToday}`,
			);
		});
	}
	return _bot;
}
