/*
 * The universal streaming unit shared with the legacy web/ agent runtime.
 * Every compute provider (Vercel Sandbox, Anthropic Managed Agents, mock)
 * emits these; the transcript adapter turns them into AI SDK UIMessage chunks.
 */
export interface StreamChunk {
	type:
		| "text"
		| "reasoning"
		| "tool_use"
		| "tool_result"
		| "status"
		| "error"
		| "done";
	content: string;
	metadata?: Record<string, unknown>;
}
