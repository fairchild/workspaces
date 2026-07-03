"use client";

/*
 * Contextual diff card: a landed edit surfaces as a raised, dismissible
 * figure — file + delta caption, then the hunk with add/del washes.
 * Takes structured DiffCardData; #748 maps real Edit results onto it.
 */
import { useState } from "react";
import type { DiffCardData, DiffLine } from "./types";

const LINE_CLASS: Record<DiffLine["kind"], string> = {
	context: "",
	add: "bg-add-bg text-add-ink",
	del: "bg-del-bg text-del-ink line-through [text-decoration-color:var(--del-strike)]",
};

export function DiffCard({ diff }: { diff: DiffCardData }) {
	const [dismissed, setDismissed] = useState(false);
	if (dismissed) return null;
	return (
		<figure
			data-testid="diff-card"
			className="group/landed animate-settle my-[30px] overflow-hidden rounded-xl border border-line bg-raised shadow-card"
		>
			<figcaption className="flex items-baseline gap-3 border-b border-line px-[18px] py-[11px] font-mono text-caption text-muted">
				<span className="font-medium text-ink">{diff.file}</span>
				<span>
					<span className="text-add-ink">+{diff.additions}</span>
					<span className="ml-1.5 text-del-ink">−{diff.deletions}</span>
				</span>
				{diff.note !== undefined && (
					<span className="ml-auto font-serif text-[12.5px] italic text-faint">
						{diff.note}
					</span>
				)}
				<button
					type="button"
					title="Dismiss"
					aria-label="Dismiss diff card"
					onClick={() => setDismissed(true)}
					className={`pl-2.5 text-[13px] leading-none text-faint opacity-0 transition-opacity duration-200 group-hover/landed:opacity-100 hover:text-ink ${diff.note === undefined ? "ml-auto" : ""}`}
				>
					✕
				</button>
			</figcaption>
			<pre className="overflow-x-auto py-3 font-mono text-tool leading-[1.7]">
				{diff.lines.map((line, i) => (
					<span
						key={i}
						className={`block px-[18px] py-px whitespace-pre text-muted ${LINE_CLASS[line.kind]}`}
					>
						{line.text}
					</span>
				))}
			</pre>
		</figure>
	);
}
