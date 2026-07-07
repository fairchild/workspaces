/*
 * Client-only patch for a turn that errors while streaming live. The SDK's
 * chunk pipeline throws on the stream's `error` chunk (@ai-sdk/react's
 * `processUIMessageStream` rethrows it) before the adapter's `finish` chunk —
 * which is what would normally carry `metadata.error` — ever arrives, so the
 * assistant message useChat already pushed at `start` never gets tagged.
 * `withLiveTurnError` reproduces that tag locally from the hook's
 * `status`/`error` state, so the live and reloaded failure states render
 * through the exact same Message component (see chunk-adapter.ts's
 * `case "error"` and turn-stats.ts's `deriveTurnError` for the server-side
 * half of this contract, which projection relies on directly).
 */
import type { FolioMessage } from "@/components/folio/types";

/**
 * Tags the trailing assistant message with the live failure, if one hasn't
 * already been recorded. A no-op when the trailing message isn't an
 * assistant reply (nothing to tag) or already carries `metadata.error`
 * (idempotent — safe to call on every render while `status === "error"`).
 */
export function withLiveTurnError(
	messages: FolioMessage[],
	errorText: string,
	fallbackAuthor: string,
): FolioMessage[] {
	const last = messages.at(-1);
	if (!last || last.role !== "assistant" || last.metadata?.error) return messages;
	const patched: FolioMessage = {
		...last,
		metadata: {
			...last.metadata,
			author: last.metadata?.author ?? fallbackAuthor,
			error: errorText,
		},
	};
	return [...messages.slice(0, -1), patched];
}

/**
 * A message worth rendering in the transcript: it has content, or it's a
 * failed turn's card (`metadata.error` set, however few parts it produced).
 * The one case still hidden is the empty in-progress placeholder useChat
 * pushes at a turn's `start` — no parts, no failure (yet) — which the
 * standalone activity article stands in for instead (see
 * live-session-view.tsx).
 */
export function isVisibleMessage(message: FolioMessage): boolean {
	return message.parts.length > 0 || message.metadata?.error != null;
}
