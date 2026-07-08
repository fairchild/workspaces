"use client";

/*
 * Model status line: model + quiet context figures pinned under the
 * compose. ✕ collapses it to a small corner dot (the handle); the dot
 * brings it back. Expects a positioned ancestor for the handle.
 *
 * The model segment doubles as the picker (#824) whenever the caller supplies
 * both `models` (the selectable set) and `onModelChange`: it renders as a bare
 * native `<select>` styled to read as the same plain text — no visible
 * dropdown chrome, matching docs/design.md's "stated once, quietly" status
 * line. Callers that omit either (fixtures, demo pages) get the old static
 * text, unchanged.
 */
import { useState } from "react";

export interface StatusLineModelOption {
	id: string;
	label: string;
}

export interface StatusLineData {
	/** Current model id. */
	model: string;
	/** Display label for `model` (falls back to the raw id). */
	modelLabel?: string;
	/** The selectable set; present + `onModelChange` given turns on the picker. */
	models?: readonly StatusLineModelOption[];
	/** Preformatted context figure (e.g. "2.1k ctx"), or undefined to hide it —
	 * a real figure isn't known yet (no completed turn), never a fake 0. */
	contextLabel?: string;
}

export function StatusLine({
	status,
	onModelChange,
}: {
	status: StatusLineData;
	/** Wired by the live session view; omitted on fixtures/demo pages. */
	onModelChange?: (id: string) => void;
}) {
	const [dismissed, setDismissed] = useState(false);

	if (dismissed) {
		return (
			<button
				type="button"
				data-testid="status-line-handle"
				title="Show status line"
				aria-label="Show status line"
				onClick={() => setDismissed(false)}
				className="group absolute right-[0.5px] bottom-[-4.5px] flex h-11 w-11 items-center justify-center"
			>
				<span className="h-[9px] w-[9px] rounded-full bg-faint opacity-40 transition-[opacity,transform,background-color] duration-200 group-hover:scale-[1.35] group-hover:bg-accent group-hover:opacity-100" />
			</button>
		);
	}

	const picker = status.models && onModelChange;

	return (
		<div
			data-testid="status-line"
			className="h-[30px] border-t border-line bg-status-bg font-mono text-stat tracking-[.03em] text-hint"
		>
			<div className="mx-auto flex h-full max-w-[680px] items-center px-5">
				<span className="font-medium text-muted before:mr-2 before:inline-block before:h-[5px] before:w-[5px] before:rounded-full before:bg-accent before:align-[2px] before:opacity-75 before:content-['']">
					{picker ? (
						<select
							data-testid="model-select"
							aria-label="Model"
							title="Change model"
							value={status.model}
							onChange={(event) => onModelChange(event.target.value)}
							className="cursor-pointer appearance-none border-none bg-transparent p-0 font-mono font-medium text-muted outline-none"
						>
							{status.models?.map((option) => (
								<option key={option.id} value={option.id}>
									{option.label}
								</option>
							))}
						</select>
					) : (
						(status.modelLabel ?? status.model)
					)}
				</span>
				{status.contextLabel && (
					<>
						<span className="mx-[9px] text-faint opacity-55">·</span>
						{status.contextLabel}
					</>
				)}
				<button
					type="button"
					title="Hide status line"
					aria-label="Hide status line"
					onClick={() => setDismissed(true)}
					className="relative ml-auto rounded-[5px] px-1.5 py-1 text-stat leading-none text-faint opacity-70 transition-[opacity,color] duration-200 after:absolute after:top-1/2 after:left-1/2 after:h-11 after:w-11 after:-translate-x-1/2 after:-translate-y-1/2 after:content-[''] hover:text-ink hover:opacity-100"
				>
					✕
				</button>
			</div>
		</div>
	);
}
