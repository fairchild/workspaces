"use client";

/*
 * Model status line: model + quiet context figures pinned under the
 * compose. ✕ collapses it to a small corner dot (the handle); the dot
 * brings it back. Expects a positioned ancestor for the handle.
 */
import { useState } from "react";

export interface StatusLineData {
	model: string;
	/** Preformatted context figure (e.g. "2.1k ctx"). */
	contextLabel: string;
}

export function StatusLine({ status }: { status: StatusLineData }) {
	const [dismissed, setDismissed] = useState(false);

	if (dismissed) {
		return (
			<button
				type="button"
				data-testid="status-line-handle"
				title="Show status line"
				aria-label="Show status line"
				onClick={() => setDismissed(false)}
				className="absolute right-[18px] bottom-[13px] h-[9px] w-[9px] rounded-full bg-faint opacity-40 transition-[opacity,transform,background-color] duration-200 hover:scale-[1.35] hover:bg-accent hover:opacity-100"
			/>
		);
	}

	return (
		<div
			data-testid="status-line"
			className="h-[30px] border-t border-line bg-status-bg font-mono text-stat tracking-[.03em] text-faint"
		>
			<div className="mx-auto flex h-full max-w-[680px] items-center px-0.5">
				<span className="font-medium text-muted before:mr-2 before:inline-block before:h-[5px] before:w-[5px] before:rounded-full before:bg-accent before:align-[2px] before:opacity-75 before:content-['']">
					{status.model}
				</span>
				<span className="mx-[9px] opacity-55">·</span>
				{status.contextLabel}
				<button
					type="button"
					title="Hide status line"
					aria-label="Hide status line"
					onClick={() => setDismissed(true)}
					className="ml-auto rounded-[5px] px-1.5 py-1 text-stat leading-none text-faint opacity-70 transition-[opacity,color] duration-200 hover:text-ink hover:opacity-100"
				>
					✕
				</button>
			</div>
		</div>
	);
}
