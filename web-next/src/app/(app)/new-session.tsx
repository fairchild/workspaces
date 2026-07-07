"use client";

/*
 * The new-session flow: a quiet "+ new session" affordance that reveals a
 * repo picker inline — the GitHub App installation's repos as one-click rows
 * (fetched from /api/repos, filtered live by the same field used to type a
 * freetext owner/name), plus that field as the escape hatch for a repo not
 * yet surfaced. Starts open when the home has nothing else to show.
 * Submission goes through createSessionAction (via useActionState, shared
 * across every row's form and the freetext form), which validates the repo
 * against GitHub, creates the row, and routes to the new session — or
 * returns a calm inline error if GitHub can't find or access it.
 */
import { useActionState, useEffect, useRef, useState } from "react";
import { createSessionAction, type CreateSessionState } from "./actions";

/** Mirror of the /api/repos response item (see mergeRepoLists). */
interface PickerRepo {
	fullName: string;
	defaultBranch: string | null;
}

export function NewSession({ startOpen = false }: { startOpen?: boolean }) {
	const [open, setOpen] = useState(startOpen);
	const [query, setQuery] = useState("");
	const [repos, setRepos] = useState<PickerRepo[] | null>(null);
	const [degraded, setDegraded] = useState(false);
	const inputRef = useRef<HTMLInputElement>(null);
	const [state, formAction, isPending] = useActionState<
		CreateSessionState | null,
		FormData
	>(createSessionAction, null);

	// Focus the owner/name field when the picker is revealed by hand (not on
	// the empty home, where stealing focus would be presumptuous).
	useEffect(() => {
		if (open && !startOpen) inputRef.current?.focus();
	}, [open, startOpen]);

	// Fetch the pickable repos (installation directory + already connected)
	// once, the first time the picker opens.
	useEffect(() => {
		if (!open || repos !== null) return;
		let cancelled = false;
		fetch("/api/repos")
			.then((res) => res.json())
			.then((data: { repos: PickerRepo[]; degraded: boolean }) => {
				if (cancelled) return;
				setRepos(data.repos);
				setDegraded(data.degraded);
			})
			.catch(() => {
				if (!cancelled) setRepos([]);
			});
		return () => {
			cancelled = true;
		};
	}, [open, repos]);

	if (!open) {
		return (
			<button
				type="button"
				onClick={() => setOpen(true)}
				className="font-mono text-[13px] text-faint transition-colors hover:text-accent"
			>
				+ new session
			</button>
		);
	}

	const visible = (repos ?? []).filter((repo) =>
		repo.fullName.toLowerCase().includes(query.trim().toLowerCase()),
	);

	return (
		<div
			data-testid="new-session-picker"
			className="animate-rise-fast"
			onKeyDown={(event) => {
				if (event.key === "Escape" && !startOpen) setOpen(false);
			}}
		>
			{visible.length > 0 && (
				<ul className="mb-1">
					{visible.map((repo) => (
						<li key={repo.fullName}>
							<form action={formAction}>
								<input type="hidden" name="repo" value={repo.fullName} />
								<button
									type="submit"
									disabled={isPending}
									className="w-full rounded-md px-2.5 py-2 text-left font-mono text-[13px] text-item-ink transition-colors hover:bg-hover-bg hover:text-accent disabled:pointer-events-none disabled:opacity-60"
								>
									{repo.fullName}
								</button>
							</form>
						</li>
					))}
				</ul>
			)}
			<form
				action={formAction}
				// One shared action across every row form and this one: swallow
				// re-submits while a create is in flight (double-Enter would queue
				// a second session) without disabling the input and losing focus.
				onSubmit={(event) => {
					if (isPending) event.preventDefault();
				}}
				className="flex items-center gap-2.5 px-2.5 py-2"
			>
				<span aria-hidden className="font-mono text-[13px] text-accent">
					›
				</span>
				<input
					ref={inputRef}
					type="text"
					name="repo"
					value={query}
					onChange={(event) => setQuery(event.target.value)}
					required
					pattern="[A-Za-z0-9][A-Za-z0-9_.\-]*\/[A-Za-z0-9_.\-]+"
					title="owner/repository"
					aria-label="Repository (owner/name)"
					placeholder="owner/repository — search or connect"
					autoComplete="off"
					spellCheck={false}
					className="min-w-0 flex-1 border-b border-line bg-transparent pb-1 font-mono text-[13px] text-ink transition-colors outline-none placeholder:text-faint focus:border-focus-line"
				/>
			</form>
			{state?.error && !isPending && (
				<p
					data-testid="new-session-error"
					className="px-2.5 pt-1 font-mono text-caption text-faint italic"
				>
					{state.error}
				</p>
			)}
			{degraded && !state?.error && (
				<p className="px-2.5 pt-1 font-mono text-caption text-faint italic">
					Repositories aren&apos;t verified against GitHub right now — entries
					are accepted unverified.
				</p>
			)}
		</div>
	);
}
