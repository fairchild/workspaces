/*
 * Adapts the agent runtime's StreamChunk protocol to the AI SDK's
 * UIMessageChunk stream, so any ComputeProvider renders as structured
 * message parts (text blocks, dynamic tool cards, transient status).
 */
import type { UIMessageChunk } from "ai";
import type { StreamChunk } from "../agent-runtime/stream-chunk";

export interface AdapterOptions {
	messageId?: string;
	generateId?: () => string;
}

function defaultGenerateId(): string {
	return crypto.randomUUID();
}

function asString(value: unknown): string | undefined {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

/**
 * Converts a provider StreamChunk sequence into UIMessageChunks.
 *
 * Contract:
 * - Contiguous `text` chunks form one text part; any tool/error chunk closes it.
 * - `tool_use`/`tool_result` become dynamic tool parts. Results pair by
 *   `metadata.toolUseId` when present, otherwise FIFO against unresolved calls.
 * - `status` becomes a transient `data-status` chunk (delivered via onData,
 *   never persisted into the message).
 * - `done` — or the source ending — closes open parts and emits `finish`.
 */
export async function* toUIMessageChunks(
	source: AsyncIterable<StreamChunk> | Iterable<StreamChunk>,
	options: AdapterOptions = {},
): AsyncGenerator<UIMessageChunk> {
	const generateId = options.generateId ?? defaultGenerateId;

	let openTextId: string | null = null;
	let finished = false;
	const unresolvedToolIds: string[] = [];

	function closeText(): UIMessageChunk[] {
		if (openTextId === null) return [];
		const end: UIMessageChunk = { type: "text-end", id: openTextId };
		openTextId = null;
		return [end];
	}

	yield { type: "start", messageId: options.messageId };

	for await (const chunk of source) {
		if (finished) break;

		switch (chunk.type) {
			case "text": {
				if (chunk.content.length === 0) break;
				if (openTextId === null) {
					openTextId = generateId();
					yield { type: "text-start", id: openTextId };
				}
				yield { type: "text-delta", id: openTextId, delta: chunk.content };
				break;
			}
			case "tool_use": {
				yield* closeText();
				const toolCallId =
					asString(chunk.metadata?.toolUseId) ?? generateId();
				const toolName =
					asString(chunk.metadata?.toolName) ??
					asString(chunk.content) ??
					"tool";
				unresolvedToolIds.push(toolCallId);
				yield {
					type: "tool-input-available",
					toolCallId,
					toolName,
					input: chunk.metadata?.input ?? chunk.content,
					dynamic: true,
				};
				break;
			}
			case "tool_result": {
				yield* closeText();
				const explicitId = asString(chunk.metadata?.toolUseId);
				const toolCallId = explicitId ?? unresolvedToolIds[0];
				if (toolCallId === undefined) break; // result with no known call
				const index = unresolvedToolIds.indexOf(toolCallId);
				if (index !== -1) unresolvedToolIds.splice(index, 1);
				yield {
					type: chunk.metadata?.isError
						? "tool-output-error"
						: "tool-output-available",
					toolCallId,
					...(chunk.metadata?.isError
						? { errorText: chunk.content }
						: { output: chunk.metadata?.output ?? chunk.content }),
					dynamic: true,
				} as UIMessageChunk;
				break;
			}
			case "status": {
				yield {
					type: "data-status",
					data: { message: chunk.content },
					transient: true,
				};
				break;
			}
			case "error": {
				yield* closeText();
				yield { type: "error", errorText: chunk.content };
				break;
			}
			case "done": {
				finished = true;
				break;
			}
		}
	}

	yield* closeText();
	yield { type: "finish" };
}

/** Wraps the adapted stream as a ReadableStream for createUIMessageStreamResponse. */
export function toUIMessageChunkStream(
	source: AsyncIterable<StreamChunk> | Iterable<StreamChunk>,
	options: AdapterOptions = {},
): ReadableStream<UIMessageChunk> {
	const iterator = toUIMessageChunks(source, options);
	return new ReadableStream<UIMessageChunk>({
		async pull(controller) {
			const { value, done } = await iterator.next();
			if (done) controller.close();
			else controller.enqueue(value);
		},
		async cancel() {
			await iterator.return(undefined);
		},
	});
}
