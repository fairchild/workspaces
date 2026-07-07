"use client";

/*
 * Session masthead: identity kept to a whisper — repo/branch on the left,
 * the session title centered in serif italic, agent + sandbox state and
 * the theme toggle on the right. Sticky, translucent, blurred.
 *
 * The title is inline-editable (#823) whenever the caller supplies
 * `onTitleChange`: it becomes a bare `<input>` styled to read as the same
 * plain italic text — no border, no button — that only reveals it's a field
 * on hover/focus (a quiet background wash), matching the status line's model
 * picker (status-line.tsx). Callers that omit it (fixtures, demo pages) get
 * the old static span, unchanged.
 */
import { useRef } from "react";
import { ThemeToggle } from "./theme-toggle";

export interface MastheadData {
	repo: string;
	/** `null` = unknown (repo connected unverified); the segment is omitted. */
	branch: string | null;
	/** The session's current best title, possibly `""` (no title yet). */
	title: string;
	agentName: string;
	/** e.g. "sandbox active"; `live` adds the green halo dot. */
	stateLabel: string;
	live?: boolean;
}

/** Shown wherever a title has none yet — never "Untitled": the tab a user is
 * actually in reads as a fresh session, not a broken one. */
export const UNTITLED_MASTHEAD_TITLE = "New session";

function Separator() {
	return <span className="mx-[7px] text-faint">·</span>;
}

export function SessionMasthead({
	session,
	onTitleChange,
}: {
	session: MastheadData;
	/** Wired by the live session view; omitted on fixtures/demo pages. */
	onTitleChange?: (title: string) => void;
}) {
	const inputRef = useRef<HTMLInputElement>(null);

	const commit = () => {
		const input = inputRef.current;
		if (!input) return;
		const next = input.value.trim();
		if (next && next !== session.title) {
			onTitleChange?.(next);
		} else {
			input.value = session.title;
		}
	};

	return (
		<header className="sticky top-0 z-20 flex h-[52px] items-center justify-between gap-3 border-b border-line bg-mast-bg px-5 font-mono text-masthead tracking-[.02em] text-muted backdrop-blur-[10px] backdrop-saturate-[1.1] sm:px-8">
			<span className="min-w-0 truncate whitespace-nowrap">
				<b className="font-medium text-ink">{session.repo}</b>
				{session.branch && (
					<>
						<Separator />
						{session.branch}
					</>
				)}
			</span>
			{onTitleChange ? (
				<input
					key={session.title}
					ref={inputRef}
					type="text"
					data-testid="session-title"
					aria-label="Session title"
					defaultValue={session.title}
					placeholder={UNTITLED_MASTHEAD_TITLE}
					size={1}
					onBlur={commit}
					onKeyDown={(event) => {
						if (event.key === "Enter") {
							event.currentTarget.blur();
						} else if (event.key === "Escape") {
							event.currentTarget.value = session.title;
							event.currentTarget.blur();
						}
					}}
					className="absolute left-1/2 hidden w-[46%] max-w-[420px] -translate-x-1/2 truncate rounded-[6px] border-none bg-transparent px-1.5 py-0.5 text-center font-serif text-title text-faint italic tracking-[.01em] outline-none transition-colors duration-150 placeholder:text-faint hover:bg-hover-bg hover:text-ink focus:bg-hover-bg focus:text-ink focus:shadow-[0_0_0_3px_var(--focus-ring)] md:block"
				/>
			) : (
				<span className="absolute left-1/2 hidden -translate-x-1/2 font-serif text-title italic tracking-[.01em] text-faint md:block">
					{session.title || UNTITLED_MASTHEAD_TITLE}
				</span>
			)}
			<span className="flex shrink-0 items-center whitespace-nowrap">
				{session.agentName}
				<Separator />
				{session.live && (
					<span className="mr-2 inline-block h-[7px] w-[7px] rounded-full bg-live align-[1px] shadow-[0_0_0_3px_var(--live-halo)]" />
				)}
				{session.stateLabel}
				<ThemeToggle />
			</span>
		</header>
	);
}
