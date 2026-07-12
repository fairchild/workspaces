/*
 * Renders Folio inline markdown (`code` spans, *emphasis*) as elements.
 * Parsing lives in parse-inline.ts.
 */
import type { ReactNode } from "react";
import { parseInline } from "./parse-inline";

export function InlineMarkdown({ text }: { text: string }): ReactNode {
	return parseInline(text).map((token, i) => {
		if (token.kind === "code") return <code key={i}>{token.text}</code>;
		if (token.kind === "em") return <em key={i}>{token.text}</em>;
		return token.text;
	});
}
