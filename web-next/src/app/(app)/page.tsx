/*
 * The sessions home: active and recent sessions, most recent first, with
 * the quiet new-session flow. This is the app's front door — everything on
 * it stays calm: one masthead, one list, one affordance.
 */
import Link from "next/link";
import { ThemeToggle } from "@/components/folio/theme-toggle";
import { getDatabase } from "@/lib/db/client";
import { listRepos } from "@/lib/db/repos";
import { listSessions, type SessionListItem } from "@/lib/db/sessions";
import { formatRelativeTime } from "@/lib/relative-time";
import { NewSession } from "./new-session";

function SessionRow({ session, index }: { session: SessionListItem; index: number }) {
	return (
		<li
			className="animate-rise border-b border-line"
			style={index < 6 ? { animationDelay: `${0.03 + index * 0.05}s` } : undefined}
		>
			<Link
				href={`/sessions/${session.id}`}
				className="group block px-2.5 py-[16px]"
			>
				{session.title ? (
					<span className="font-serif text-body text-ink transition-colors group-hover:text-accent">
						{session.title}
					</span>
				) : (
					<span className="font-serif text-body text-faint italic transition-colors group-hover:text-accent">
						Untitled session
					</span>
				)}
				<span className="mt-1 flex items-baseline gap-[9px] font-mono text-caption text-muted">
					{session.repoFullName ?? "no repository"}
					<span className="text-faint">·</span>
					{formatRelativeTime(session.lastActivityAt)}
					{session.status !== "active" && (
						<>
							<span className="text-faint">·</span>
							<span className="text-faint">{session.status}</span>
						</>
					)}
				</span>
			</Link>
		</li>
	);
}

export default async function SessionsHome() {
	const handle = getDatabase();
	const [sessions, repos] = await Promise.all([
		listSessions(handle),
		listRepos(handle),
	]);
	const isEmpty = sessions.length === 0;

	return (
		<>
			<header className="sticky top-0 z-20 flex h-[52px] items-center justify-between border-b border-line bg-mast-bg px-8 backdrop-blur-[10px] backdrop-saturate-[1.1]">
				<span className="font-serif text-[17px] text-ink italic">Spaces</span>
				<span className="flex items-center font-mono text-masthead tracking-[.02em] text-muted">
					sessions
					<ThemeToggle />
				</span>
			</header>
			<main className="mx-auto max-w-[680px] px-5 pt-[72px] pb-16">
				{isEmpty ? (
					<div className="animate-rise flex flex-col items-center pt-[14vh]">
						<p className="font-serif text-body text-muted italic">
							No sessions yet.
						</p>
						<p className="mt-2 mb-10 font-mono text-caption text-faint">
							Start one on a repository.
						</p>
						<div className="w-full max-w-[380px]">
							<NewSession repos={repos} startOpen />
						</div>
					</div>
				) : (
					<>
						<h1 className="mb-2 px-2.5 font-mono text-label font-medium tracking-[.16em] text-faint uppercase">
							Sessions
						</h1>
						<ul>
							{sessions.map((session, index) => (
								<SessionRow key={session.id} session={session} index={index} />
							))}
						</ul>
						{/* The list ends in a quiet invitation, not a persistent button. */}
						<div className="mt-4 px-2.5">
							<NewSession repos={repos} />
						</div>
					</>
				)}
			</main>
		</>
	);
}
