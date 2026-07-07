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

// Zero-width formatting characters (ZWSP/ZWNJ/ZWJ/BOM) render as nothing, so
// a title made of only these would look blank while passing a naive
// non-empty check — strip them alongside whitespace, not just trim around them.
const ZERO_WIDTH = /[\u200B-\u200D\uFEFF]/g;

/** Trims and collapses internal whitespace runs (including newlines) to a
 * single space, and drops zero-width formatting characters — the shared
 * cleanup for both a derived and a user-typed title. */
export function cleanTitleText(raw: string): string {
	return raw.replace(ZERO_WIDTH, "").trim().replace(/\s+/g, " ");
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
	// Split by code point (Array.from), not UTF-16 unit (slice/length) — a
	// raw slice can cut a surrogate pair in half and leave a mangled glyph
	// right before the ellipsis.
	const codePoints = Array.from(cleaned);
	if (codePoints.length <= MAX_TITLE_LENGTH) return cleaned;
	const truncated = codePoints.slice(0, MAX_TITLE_LENGTH - ELLIPSIS.length).join("");
	return `${truncated.trimEnd()}${ELLIPSIS}`;
}
