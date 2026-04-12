import Anthropic from "@anthropic-ai/sdk";
import type { AiMessage } from "chat";

let _client: Anthropic | undefined;

function getClient(): Anthropic {
	if (!_client) {
		_client = new Anthropic();
	}
	return _client;
}

const SYSTEM_PROMPT = `You are spaces-bot, an AI assistant embedded in GitHub Discussions for the Workspaces project.
You help developers with workspace state, codebase questions, PR context, and CI status.
Keep responses concise, use markdown, and stay relevant to the thread context.
If you don't have enough context to answer, say so briefly.`;

export async function* streamResponse(
	messages: AiMessage[],
	systemPrompt = SYSTEM_PROMPT,
): AsyncGenerator<string> {
	const client = getClient();

	const stream = client.messages.stream({
		model: "claude-sonnet-4-6",
		max_tokens: 1024,
		system: systemPrompt,
		messages: messages.map((m) => ({
			role: m.role,
			content:
				typeof m.content === "string"
					? m.content
					: m.content.map((p) => {
							if (p.type === "text")
								return { type: "text" as const, text: p.text };
							return { type: "text" as const, text: "[attachment]" };
						}),
		})),
	});

	for await (const event of stream) {
		if (
			event.type === "content_block_delta" &&
			event.delta.type === "text_delta"
		) {
			yield event.delta.text;
		}
	}
}

export function isAiConfigured(): boolean {
	return !!process.env.ANTHROPIC_API_KEY;
}
