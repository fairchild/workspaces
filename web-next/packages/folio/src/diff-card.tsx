/*
 * The diff hunk: add/del/context lines for a landed edit. A code edit has
 * one home — its Edit tool-ledger row (#790) — so this renders inside that
 * row's expanded body (see message.tsx's LedgerBodyView), not as a separate
 * floating card; the row's own header already carries the file + delta.
 * A long refactor stays a bounded block: past ~28 lines the hunk scrolls
 * inside its own box instead of stretching the row (and the turn) into a wall.
 */
import type { DiffLine } from "./types";

/** Beyond this many lines the hunk gets its own scroll rather than growing the row. */
const TALL_DIFF_LINES = 28;

const LINE_CLASS: Record<DiffLine["kind"], string> = {
	context: "",
	add: "bg-add-bg text-add-ink",
	del: "bg-del-bg text-del-ink line-through [text-decoration-color:var(--del-strike)]",
};

export function DiffHunk({ lines }: { lines: DiffLine[] }) {
	return (
		<pre
			data-testid="diff-lines"
			className={`overflow-x-auto rounded-lg border border-line bg-raised py-3 font-mono text-tool leading-[1.7] ${lines.length > TALL_DIFF_LINES ? "max-h-[460px] overflow-y-auto" : ""}`}
		>
			{lines.map((line, i) => (
				<span
					key={i}
					className={`block px-[18px] py-px whitespace-pre text-muted ${LINE_CLASS[line.kind]}`}
				>
					{line.text}
				</span>
			))}
		</pre>
	);
}
