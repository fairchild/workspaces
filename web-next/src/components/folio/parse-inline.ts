/*
 * Minimal inline markdown parser for Folio prose: `code` spans and
 * *emphasis*. Deliberately tiny — block markdown is out of scope until a
 * real streaming transcript (#748) demands more.
 */
export type InlineToken =
	| { kind: "text"; text: string }
	| { kind: "code"; text: string }
	| { kind: "em"; text: string };

export function parseInline(text: string): InlineToken[] {
	const tokens: InlineToken[] = [];
	const pattern = /`([^`]+)`|\*([^*]+)\*/g;
	let cursor = 0;
	for (const match of text.matchAll(pattern)) {
		if (match.index > cursor)
			tokens.push({ kind: "text", text: text.slice(cursor, match.index) });
		if (match[1] !== undefined) tokens.push({ kind: "code", text: match[1] });
		else tokens.push({ kind: "em", text: match[2] });
		cursor = match.index + match[0].length;
	}
	if (cursor < text.length) tokens.push({ kind: "text", text: text.slice(cursor) });
	return tokens;
}
