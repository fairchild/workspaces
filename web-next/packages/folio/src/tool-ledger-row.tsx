"use client";

/*
 * One step of the workings apparatus: a quiet mono row (twist · verb ·
 * subject · meta) that discloses its body on click. State is per-row;
 * nothing here knows about tools — Message maps parts onto these props.
 */
import { useState, type ReactNode } from "react";

export interface ToolLedgerRowProps {
	verb: string;
	subject: string;
	/** Right-aligned summary (e.g. "41 lines", "+4 −1", "28 passed · 1.21s"). */
	meta?: ReactNode;
	defaultOpen?: boolean;
	/** Expanded body; rows without one still render (running calls). */
	children?: ReactNode;
}

export function ToolLedgerRow({
	verb,
	subject,
	meta,
	defaultOpen = false,
	children,
}: ToolLedgerRowProps) {
	const [open, setOpen] = useState(defaultOpen);
	return (
		<div data-testid="tool-row" data-open={open || undefined}>
			<button
				type="button"
				aria-expanded={open}
				onClick={() => setOpen((current) => !current)}
				className="flex w-full items-baseline gap-2.5 rounded-md py-[5px] pr-2 text-left font-mono text-tool text-muted hover:text-ink"
			>
				<span
					aria-hidden
					className={`inline-block w-2.5 origin-[45%_50%] text-[11px] text-faint transition-transform duration-[.18s] ${open ? "rotate-90" : ""}`}
				>
					▸
				</span>
				<span className="min-w-[3.6em] text-hint">{verb}</span>
				<span className="min-w-0 flex-1 truncate">{subject}</span>
				{meta !== undefined && (
					<span className="ml-auto pl-4 text-caption whitespace-nowrap text-hint">
						{meta}
					</span>
				)}
			</button>
			{open && children !== undefined && (
				<div
					data-testid="tool-row-body"
					className="animate-rise-fast mt-2 mb-4 ml-5"
				>
					{children}
				</div>
			)}
		</div>
	);
}
