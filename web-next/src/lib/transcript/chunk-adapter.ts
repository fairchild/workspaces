/*
 * Adapts the agent runtime's StreamChunk protocol to the AI SDK's
 * UIMessageChunk stream, so any ComputeProvider renders as structured
 * message parts (text blocks, dynamic tool cards, transient status).
 */
import type { UIMessageChunk } from "ai";
import type {
	ApprovalRequestMetadata,
	ApprovalResolvedMetadata,
	StreamChunk,
} from "../agent-runtime/stream-chunk";

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
 * Folds a diff onto a tool's output, guaranteeing a string `content` so the
 * ledger's normalizeOutput never drops the diff for want of one — `fallback`
 * is the tool_result chunk's own `content` (always a string on StreamChunk),
 * used when `output` is an object that doesn't already carry its own.
 */
function withDiff(output: unknown, diff: unknown, fallback: string): unknown {
	if (typeof output === "string") return { content: output, diff };
	if (typeof output === "object" && output !== null) {
		const record = output as Record<string, unknown>;
		const content = typeof record.content === "string" ? record.content : fallback;
		return { ...record, content, diff };
	}
	return { content: fallback, diff };
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
 * - A `tool_result` carrying `metadata.diff` merges it into that same call's
 *   structured output (`{ content, summary?, diff }`) rather than emitting a
 *   separate part — the Edit ledger row is the diff's one home (#790).
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
	const approvals = new Map<
		string,
		{
			summary: string;
			toolName: string;
			inputSummary: string;
			expiresAt: string;
		}
	>();

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
				const baseOutput = chunk.metadata?.output ?? chunk.content;
				const output =
					chunk.metadata?.diff !== undefined
						? withDiff(baseOutput, chunk.metadata.diff, chunk.content)
						: baseOutput;
				yield {
					type: chunk.metadata?.isError
						? "tool-output-error"
						: "tool-output-available",
					toolCallId,
					...(chunk.metadata?.isError ? { errorText: chunk.content } : { output }),
					dynamic: true,
				} as UIMessageChunk;
				break;
			}
			case "approval_request": {
				yield* closeText();
				yield* closeReasoning();
				const metadata = chunk.metadata as
					| Partial<ApprovalRequestMetadata>
					| undefined;
				const requestId = asString(metadata?.requestId);
				const expiresAt = asString(metadata?.expiresAt);
				if (!requestId || !expiresAt) break;
				const toolName = asString(metadata?.toolName) ?? "tool";
				const inputSummary = asString(metadata?.inputSummary) ?? "";
				approvals.set(requestId, {
					summary: chunk.content,
					toolName,
					inputSummary,
					expiresAt,
				});
				yield {
					type: "data-approval",
					id: requestId,
					data: {
						state: "pending",
						requestId,
						summary: chunk.content,
						toolName,
						inputSummary,
						expiresAt,
					},
				};
				break;
			}
			case "approval_resolved": {
				yield* closeText();
				yield* closeReasoning();
				const metadata = chunk.metadata as
					| Partial<ApprovalResolvedMetadata>
					| undefined;
				const requestId = asString(metadata?.requestId);
				const decision = metadata?.decision;
				const resolvedBy = metadata?.resolvedBy;
				if (
					!requestId ||
					!(decision === "allow" || decision === "deny") ||
					!(
						resolvedBy === "user" ||
						resolvedBy === "timeout" ||
						resolvedBy === "abort"
					)
				) {
					break;
				}
				const request = approvals.get(requestId);
				yield {
					type: "data-approval",
					id: requestId,
					data: {
						state: "resolved",
						requestId,
						summary: request?.summary ?? "",
						toolName: request?.toolName ?? "tool",
						inputSummary: request?.inputSummary ?? "",
						expiresAt: request?.expiresAt,
						decision,
						resolvedBy,
					},
				};
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
