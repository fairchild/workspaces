"use client";

/*
 * In-progress turn: one quiet breathing line naming the current action,
 * with a hover-revealed "details" peek that discloses the live step list.
 * Expects to sit inside a `group` message shell (peek shows on hover).
 */
import { useState } from "react";
import { InlineMarkdown } from "./inline-markdown";

export interface ActivityDetailRow {
	state: "done" | "current";
	text: string;
}

export interface ActivityLineProps {
	/** Current action, inline-markdown (e.g. "Editing `src/session.ts`"). */
	action: string;
	details?: ActivityDetailRow[];
}

export function ActivityLine({ action, details }: ActivityLineProps) {
	const [showDetails, setShowDetails] = useState(false);
	return (
		<div data-testid="activity-line">
			<div className="flex items-center gap-3 font-mono text-[13.5px] text-muted">
				<span className="animate-breathe h-2 w-2 rounded-full bg-accent" />
				<span className="[&_code]:bg-transparent [&_code]:p-0 [&_code]:text-[13px] [&_code]:text-ink">
					<InlineMarkdown text={action} />
					<span className="ellipsis-dots" />
				</span>
				{details !== undefined && details.length > 0 && (
					<button
						type="button"
						onClick={() => setShowDetails((current) => !current)}
						className="ml-auto border-b border-transparent pb-px font-mono text-masthead tracking-[.06em] text-faint opacity-0 transition-opacity duration-[.25s] group-hover:opacity-100 hover:border-accent hover:text-accent"
					>
						details
					</button>
				)}
			</div>
			{showDetails && details !== undefined && (
				<div className="mt-3.5 ml-5" data-testid="activity-detail">
					{details.map((row, i) => (
						<div
							key={i}
							className={`flex gap-2.5 py-[3px] font-mono text-code ${row.state === "current" ? "text-muted" : "text-faint"}`}
						>
							{row.state === "current" ? (
								<span className="animate-breathe-fast text-accent">▍</span>
							) : (
								<span>✓</span>
							)}
							<span>{row.text}</span>
						</div>
					))}
				</div>
			)}
		</div>
	);
}
