"use client";

/*
 * Session masthead: identity kept to a whisper — repo/branch on the left,
 * the session title centered in serif italic, agent + sandbox state and
 * the theme toggle on the right. Sticky, translucent, blurred.
 */
import { useThemeToggle } from "./use-theme";

export interface MastheadData {
	repo: string;
	branch: string;
	title: string;
	agentName: string;
	/** e.g. "sandbox active"; `live` adds the green halo dot. */
	stateLabel: string;
	live?: boolean;
}

function Separator() {
	return <span className="mx-[7px] text-faint">·</span>;
}

export function SessionMasthead({ session }: { session: MastheadData }) {
	const toggleTheme = useThemeToggle();
	return (
		<header className="sticky top-0 z-20 flex h-[52px] items-center justify-between border-b border-line bg-mast-bg px-8 font-mono text-masthead tracking-[.02em] text-muted backdrop-blur-[10px] backdrop-saturate-[1.1]">
			<span>
				<b className="font-medium text-ink">{session.repo}</b>
				<Separator />
				{session.branch}
			</span>
			<span className="absolute left-1/2 -translate-x-1/2 font-serif text-title italic tracking-[.01em] text-faint">
				{session.title}
			</span>
			<span className="flex items-center">
				{session.agentName}
				<Separator />
				{session.live && (
					<span className="mr-2 inline-block h-[7px] w-[7px] rounded-full bg-live align-[1px] shadow-[0_0_0_3px_var(--live-halo)]" />
				)}
				{session.stateLabel}
				<button
					type="button"
					onClick={toggleTheme}
					title="Toggle light / dark"
					aria-label="Toggle light / dark theme"
					className="ml-4 rounded-md px-1.5 py-1 text-[13px] leading-none text-faint [transition:color_.2s_ease,transform_.35s_ease] hover:text-accent dark:rotate-180"
				>
					◐
				</button>
			</span>
		</header>
	);
}
