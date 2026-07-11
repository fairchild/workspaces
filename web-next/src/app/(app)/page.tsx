/*
 * The sessions home: active and recent sessions, most recent first, with
 * the quiet new-session flow. This is the app's front door — everything on
 * it stays calm: one masthead, one list, one affordance.
 */
import { ThemeToggle } from "@fairchild/folio";
import { getDatabase } from "@/lib/db/client";
import { listSessionFilterOptions, listSessions } from "@/lib/db/sessions";
import { NewSession } from "./new-session";
import { SessionsHomeList } from "./sessions-home-list";
import { SignOutButton } from "./sign-out-button";

interface SessionsHomeProps {
	searchParams?: Promise<Record<string, string | string[] | undefined>>;
}

/** Next hands repeated params (`?q=a&q=b`) through as arrays; take the first. */
function firstParam(value: string | string[] | undefined): string {
	return (Array.isArray(value) ? value[0] : value) ?? "";
}

export default async function SessionsHome({ searchParams }: SessionsHomeProps) {
	const handle = getDatabase();
	const params = (await searchParams) ?? {};
	const query = firstParam(params.q).trim();
	const repoId = firstParam(params.repo);
	const status = firstParam(params.status);
	const [sessions, filters] = await Promise.all([
		listSessions(handle, { query, repoId, status }),
		listSessionFilterOptions(handle),
	]);
	const isEmpty = sessions.length === 0;
	const hasFilters = query || repoId || status;

	return (
		<>
			<header className="sticky top-0 z-20 flex h-[52px] items-center justify-between border-b border-line bg-mast-bg px-8 backdrop-blur-[10px] backdrop-saturate-[1.1]">
				<span className="font-serif text-[17px] text-ink italic">Spaces</span>
				<span className="flex items-center gap-3 font-mono text-masthead tracking-[.02em] text-muted">
					sessions
					<SignOutButton variant="masthead" />
					<ThemeToggle />
				</span>
			</header>
			<main className="mx-auto max-w-[680px] px-5 pt-[72px] pb-16">
				{isEmpty && !hasFilters ? (
					<div className="animate-rise flex flex-col items-center pt-[14vh]">
						<p className="font-serif text-body text-muted italic">
							No sessions yet.
						</p>
						<p className="mt-2 mb-10 font-mono text-caption text-hint">
							Start one on a repository.
						</p>
						<div className="w-full max-w-[380px]">
							<NewSession startOpen />
						</div>
					</div>
				) : (
					<>
						<h1 className="mb-2 px-2.5 font-mono text-label font-medium tracking-[.16em] text-hint uppercase">
							Sessions
						</h1>
						<SessionsHomeList
							sessions={sessions}
							filters={filters}
							initialQuery={query}
							initialRepoId={repoId}
							initialStatus={status}
						/>
					</>
				)}
			</main>
		</>
	);
}
