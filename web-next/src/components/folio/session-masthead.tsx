/*
 * Session masthead: identity kept to a whisper — repo/branch on the left,
 * the session title centered in serif italic, agent + sandbox state and
 * the theme toggle on the right. Sticky, translucent, blurred.
 */
import { ThemeToggle } from "./theme-toggle";

export interface MastheadData {
	repo: string;
	/** `null` = unknown (repo connected unverified); the segment is omitted. */
	branch: string | null;
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
			<span className="absolute left-1/2 hidden -translate-x-1/2 font-serif text-title italic tracking-[.01em] text-faint md:block">
				{session.title}
			</span>
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
