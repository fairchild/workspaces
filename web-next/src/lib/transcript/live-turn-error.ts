/*
 * Client-only patch for a turn that errors while streaming live. The SDK's
 * chunk pipeline throws on the stream's `error` chunk (@ai-sdk/react's
 * `processUIMessageStream` rethrows it) before the adapter's `finish` chunk —
 * which is what would normally carry `metadata.error` — ever arrives, so the
 * assistant message useChat already pushed at `start` never gets tagged.
 * `applyLiveTurnErrors` reproduces that tag locally from a *sticky* record of
 * failures keyed by message id (live-session-view.tsx populates it from the
 * hook's `status`/`error` state), so the live and reloaded failure states
 * render through the exact same Message component (see chunk-adapter.ts's
 * `case "error"` and turn-stats.ts's `deriveTurnError` for the server-side
 * half of this contract, which projection relies on directly).
 *
 * Sticky, not derived-from-current-status: a naive "patch the trailing
 * message while status === 'error'" only holds while that message stays both
 * trailing AND the hook's status hasn't moved on. The moment a later turn
 * starts (e.g. its own Retry), status leaves "error" and a new message
 * becomes trailing — a status-gated patch would silently un-tag the earlier
 * failure, making its card vanish from the live view (only a reload would
 * bring it back, via project-events.ts's independent persisted tagging).
 * Recording each failure once, by the id it was caught on, keeps it tagged
 * for the rest of the session regardless of what happens afterward.
 */
import type { FolioMessage } from "@/components/folio/types";

/** Matches turn-stats.ts's deriveTurnError fallback for an empty error chunk
 * — keeps the live and projected text identical in that edge case too. */
const EMPTY_ERROR_FALLBACK = "The turn failed.";

/** messageId -> error text, accumulated for the life of the session view. */
export type LiveTurnErrors = Readonly<Record<string, string>>;

/**
 * Records the trailing assistant message's failure, if the hook just entered
 * `status === "error"` and that message isn't already recorded — a no-op
 * otherwise (including on every later re-render, since the id is already a
 * key). Returns the SAME object when nothing changed, so callers can use it
 * as a `setState` updater without triggering an extra render.
 */
export function recordLiveTurnError(
	current: LiveTurnErrors,
	messages: readonly FolioMessage[],
	errorText: string,
): LiveTurnErrors {
	const last = messages.at(-1);
	if (!last || last.role !== "assistant" || current[last.id] !== undefined) {
		return current;
	}
	return { ...current, [last.id]: errorText.length > 0 ? errorText : EMPTY_ERROR_FALLBACK };
}

/** Tags every message with a recorded failure, leaving the rest untouched. */
export function applyLiveTurnErrors(
	messages: FolioMessage[],
	failures: LiveTurnErrors,
	fallbackAuthor: string,
): FolioMessage[] {
	if (Object.keys(failures).length === 0) return messages;
	return messages.map((message) => {
		const errorText = failures[message.id];
		if (errorText === undefined || message.metadata?.error !== undefined) return message;
		return {
			...message,
			metadata: {
				...message.metadata,
				author: message.metadata?.author ?? fallbackAuthor,
				error: errorText,
			},
		};
	});
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
