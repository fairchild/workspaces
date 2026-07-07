/*
 * Session title text rules — the single source of truth for both the
 * auto-titler (turn-ingest.ts, derives from the first user message) and the
 * inline-edit PATCH route (validates a user-typed title). Deterministic by
 * design (#823): a model-generated upgrade can swap `deriveSessionTitle`'s
 * body later without touching either call site or the shared cap/cleaning
 * rules.
 */

/** Titles never exceed this many characters (ellipsis included). */
export const MAX_TITLE_LENGTH = 72;

const ELLIPSIS = "…";

/** Trims and collapses internal whitespace runs (including newlines) to a
 * single space — the shared cleanup for both a derived and a user-typed title. */
export function cleanTitleText(raw: string): string {
	return raw.trim().replace(/\s+/g, " ");
}

/**
 * Derives a title from a session's first user message: its first line,
 * cleaned and capped. Returns `""` when the message has no usable first
 * line (empty/whitespace, or a leading blank line) — callers treat that as
 * "no title yet", not an error; the session stays untitled until a message
 * that actually has one.
 */
export function deriveSessionTitle(firstUserMessage: string): string {
	const firstLine = firstUserMessage.split(/\r?\n/, 1)[0] ?? "";
	const cleaned = cleanTitleText(firstLine);
	if (!cleaned) return "";
	if (cleaned.length <= MAX_TITLE_LENGTH) return cleaned;
	return `${cleaned.slice(0, MAX_TITLE_LENGTH - ELLIPSIS.length).trimEnd()}${ELLIPSIS}`;
}
