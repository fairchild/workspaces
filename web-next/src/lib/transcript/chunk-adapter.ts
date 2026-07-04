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
	/**
	 * Message metadata factory. Called with the chunks consumed so far and
	 * emitted twice: on `start` (no chunks yet — e.g. the author label) and on
	 * `finish` (the whole turn — e.g. derived turn stats).
	 */
	messageMetadata?: (chunks: readonly StreamChunk[]) => unknown;
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
 * - Contiguous `reasoning` chunks form one reasoning part (the model's thinking);
 *   it and an open text part close each other, so the two never overlap.
 * - `tool_use`/`tool_result` become dynamic tool parts. Results pair by
 *   `metadata.toolUseId` when present, otherwise FIFO against unresolved calls.
 * - A `tool_result` carrying `metadata.diff` additionally surfaces it as a
 *   persistent `data-diff` part (the Folio contextual diff card).
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
	let openReasoningId: string | null = null;
	let finished = false;
	const unresolvedToolIds: string[] = [];
	const consumed: StreamChunk[] = [];

	function closeText(): UIMessageChunk[] {
		if (openTextId === null) return [];
		const end: UIMessageChunk = { type: "text-end", id: openTextId };
		openTextId = null;
		return [end];
	}

	function closeReasoning(): UIMessageChunk[] {
		if (openReasoningId === null) return [];
		const end: UIMessageChunk = { type: "reasoning-end", id: openReasoningId };
		openReasoningId = null;
		return [end];
	}

	yield {
		type: "start",
		messageId: options.messageId,
		messageMetadata: options.messageMetadata?.(consumed),
	};

	for await (const chunk of source) {
		if (finished) break;
		consumed.push(chunk);

		switch (chunk.type) {
			case "text": {
				if (chunk.content.length === 0) break;
				yield* closeReasoning();
				if (openTextId === null) {
					openTextId = generateId();
					yield { type: "text-start", id: openTextId };
				}
				yield { type: "text-delta", id: openTextId, delta: chunk.content };
				break;
			}
			case "reasoning": {
				if (chunk.content.length === 0) break;
				yield* closeText();
				if (openReasoningId === null) {
					openReasoningId = generateId();
					yield { type: "reasoning-start", id: openReasoningId };
				}
				yield {
					type: "reasoning-delta",
					id: openReasoningId,
					delta: chunk.content,
				};
				break;
			}
			case "tool_use": {
				yield* closeText();
				yield* closeReasoning();
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
				yield* closeReasoning();
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
				if (chunk.metadata?.diff !== undefined) {
					yield {
						type: "data-diff",
						id: generateId(),
						data: chunk.metadata.diff,
					};
				}
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
				yield* closeReasoning();
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
	yield* closeReasoning();
	yield {
		type: "finish",
		messageMetadata: options.messageMetadata?.(consumed),
	};
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
