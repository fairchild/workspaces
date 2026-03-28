import { createGitHubAdapter } from "@chat-adapter/github";
import { type SlackAdapter, createSlackAdapter } from "@chat-adapter/slack";
import { createMemoryState } from "@chat-adapter/state-memory";
import { Chat } from "chat";
import { getEventStats } from "./events";

let _bot: Chat | undefined;

function buildAdapters(): Record<
	string,
	ReturnType<typeof createGitHubAdapter> | SlackAdapter
> {
	const appId = process.env.GITHUB_APP_ID ?? "";
	const privateKey = (process.env.GITHUB_PRIVATE_KEY ?? "").replace(
		/\\n/g,
		"\n",
	);

	const adapters: Record<
		string,
		ReturnType<typeof createGitHubAdapter> | SlackAdapter
	> = {
		github: createGitHubAdapter({
			appId,
			privateKey,
			webhookSecret: process.env.GITHUB_WEBHOOK_SECRET,
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

/** Get the Slack adapter if configured. Returns null when SLACK_BOT_TOKEN is not set. */
export function getSlackAdapter(): SlackAdapter | null {
	const bot = getBot();
	try {
		return bot.getAdapter("slack") as SlackAdapter;
	} catch {
		return null;
	}
}
