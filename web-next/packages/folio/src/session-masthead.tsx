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
 *
 * The decorative centered title (input or span) is `md:block` — hidden below
 * md, same as before. A real, unconditional `sr-only` `<h1>` (#805) carries
 * the session's semantic heading and gives screen readers a title at every
 * viewport width, since the decorative copy alone is invisible on phones.
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
	/** e.g. "sandbox live"; `""` (state not yet known) omits the segment —
	 * absence over a guess, per #753's truthful-state rule. */
	stateLabel: string;
	live?: boolean;
	pullRequest?: {
		number: number;
		url: string;
		state: string;
	} | null;
	pullRequestAction?: {
		head: string;
		base: string;
		enabled: boolean;
		reason?: string;
	} | null;
	pullRequestError?: string | null;
	pullRequestBusy?: boolean;
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
	onSandboxStop,
	onPullRequestAction,
}: {
	session: MastheadData;
	/** Wired by the live session view; omitted on fixtures/demo pages. */
	onTitleChange?: (title: string) => void;
	/** Stops the session's live sandbox (#753). Supplied only when there is
	 * actually something running to stop; a quiet hover-revealed action beside
	 * the state label, never persistent chrome. */
	onSandboxStop?: () => void;
	/** Opens or updates the session PR (#820). Supplied by live session pages. */
	onPullRequestAction?: () => void;
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
	const showPullRequestLine =
		!!session.pullRequest ||
		!!session.pullRequestAction ||
		!!session.pullRequestError;
	const prAction = session.pullRequestAction;
	const prButtonLabel = session.pullRequest ? "Update PR" : "Open PR";

	return (
		<div className="sticky top-0 z-20 border-b border-line bg-mast-bg font-mono text-masthead tracking-[.02em] text-muted backdrop-blur-[10px] backdrop-saturate-[1.1]">
			<header className="flex h-[52px] items-center justify-between gap-3 px-5 sm:px-8">
				<span className="min-w-0 truncate whitespace-nowrap">
					<b className="font-medium text-ink">{session.repo}</b>
					{session.branch && (
						<>
							<Separator />
							{session.branch}
						</>
					)}
				</span>
				{/* Real heading (#805): present at every width regardless of the
				    decorative copy's md:block gating, visually unchanged. */}
				<h1 className="sr-only">{session.title || UNTITLED_MASTHEAD_TITLE}</h1>
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
						className="absolute left-1/2 hidden w-[46%] max-w-[420px] -translate-x-1/2 truncate rounded-[6px] border-none bg-transparent px-1.5 py-0.5 text-center font-serif text-title text-hint italic tracking-[.01em] outline-none transition-colors duration-150 placeholder:text-hint hover:bg-hover-bg hover:text-ink focus:bg-hover-bg focus:text-ink focus:shadow-[0_0_0_3px_var(--focus-ring)] md:block"
					/>
				) : (
					<span className="absolute left-1/2 hidden -translate-x-1/2 font-serif text-title italic tracking-[.01em] text-hint md:block">
						{session.title || UNTITLED_MASTHEAD_TITLE}
					</span>
				)}
				<span className="flex shrink-0 items-center whitespace-nowrap">
					{/* The agent name yields first at phone widths — the sandbox state is
					    the load-bearing fact on the right (#753). */}
					<span className="hidden items-center sm:flex">
						{session.agentName}
						{session.stateLabel && <Separator />}
					</span>
					{session.stateLabel && (
						<span
							data-testid="sandbox-state"
							className="group/sandbox flex items-center"
						>
							{session.live && (
								<span className="mr-2 inline-block h-[7px] w-[7px] rounded-full bg-live align-[1px] shadow-[0_0_0_3px_var(--live-halo)]" />
							)}
							{session.stateLabel}
							{onSandboxStop && (
								<button
									type="button"
									data-testid="sandbox-stop"
									title="Stop the sandbox"
									aria-label="Stop sandbox"
									onClick={onSandboxStop}
									className="ml-2 rounded-[5px] border-b border-transparent px-1 py-0.5 leading-none text-hint opacity-0 transition-opacity duration-200 group-hover/sandbox:opacity-100 hover:text-del-ink focus-visible:opacity-100"
								>
									stop
								</button>
							)}
						</span>
					)}
					<ThemeToggle />
				</span>
			</header>
			{showPullRequestLine && (
				<div
					data-testid="session-pr-line"
					className="flex min-h-7 items-center gap-2 border-t border-line/70 px-5 py-1 text-hint sm:px-8"
				>
					{session.pullRequest ? (
						<a
							href={session.pullRequest.url}
							target="_blank"
							rel="noreferrer"
							className="border-b border-transparent pb-px text-muted hover:border-accent hover:text-accent"
						>
							PR #{session.pullRequest.number} {session.pullRequest.state}
						</a>
					) : (
						<span>PR</span>
					)}
					{prAction && (
						<>
							<Separator />
							<span className="min-w-0 truncate">
								{prAction.head} → {prAction.base}
							</span>
							<button
								type="button"
								data-testid="open-session-pr"
								onClick={onPullRequestAction}
								disabled={!prAction.enabled || session.pullRequestBusy}
								title={prAction.enabled ? prButtonLabel : prAction.reason}
								className="ml-auto rounded-[5px] border-b border-transparent px-1.5 py-0.5 text-muted transition-colors hover:border-accent hover:text-accent disabled:cursor-not-allowed disabled:text-faint disabled:hover:border-transparent"
							>
								{session.pullRequestBusy ? "Opening" : prButtonLabel}
							</button>
						</>
					)}
					{!prAction?.enabled && prAction?.reason && (
						<span className="ml-auto text-faint">{prAction.reason}</span>
					)}
					{session.pullRequestError && (
						<span className="ml-auto text-del-ink">{session.pullRequestError}</span>
					)}
				</div>
			)}
		</div>
	);
}
