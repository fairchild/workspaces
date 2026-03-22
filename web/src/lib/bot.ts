import { createMemoryState } from "@chat-adapter/state-memory";
/** @jsxImportSource chat */
import { Chat } from "chat";

export const bot = new Chat({
	userName: process.env.BOT_USERNAME || "spaces",
	adapters: {},
	state: createMemoryState(),
});

bot.onNewMention(async (thread) => {
	await thread.subscribe();
	await thread.post("Hello from Spaces!");
});
