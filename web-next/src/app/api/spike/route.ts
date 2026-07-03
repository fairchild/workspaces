/*
 * Phase 0 spike endpoint: streams a mock provider turn through the
 * StreamChunk → UIMessageChunk adapter as an AI SDK UIMessage SSE response.
 */
import { createUIMessageStreamResponse, type UIMessage } from "ai";
import { toUIMessageChunkStream } from "@/lib/transcript/chunk-adapter";
import { mockCodingTurn } from "@/lib/transcript/mock-turn";

export async function POST(req: Request) {
	const { messages }: { messages: UIMessage[] } = await req.json();
	const lastUser = [...messages].reverse().find((m) => m.role === "user");
	const userText =
		lastUser?.parts
			.filter((p) => p.type === "text")
			.map((p) => p.text)
			.join("") ?? "";

	return createUIMessageStreamResponse({
		stream: toUIMessageChunkStream(mockCodingTurn(userText)),
	});
}
