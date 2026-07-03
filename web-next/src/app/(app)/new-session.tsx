"use client";

/*
 * The new-session flow: a quiet "+ new session" affordance that reveals a
 * repo picker inline — known repos as one-click rows, plus an owner/name
 * field for connecting a repo that isn't in the table yet (no GitHub API
 * validation; single-user). Starts open when the home has nothing else to
 * show. Submission goes through the createSessionAction server action,
 * which creates the row and routes to the new session.
 */
import { useEffect, useRef, useState } from "react";
import { createSessionAction } from "./actions";

export interface PickableRepo {
	id: string;
	fullName: string;
}

export function NewSession({
	repos,
	startOpen = false,
}: {
	repos: PickableRepo[];
	startOpen?: boolean;
}) {
	const [open, setOpen] = useState(startOpen);
	const inputRef = useRef<HTMLInputElement>(null);

	// Focus the owner/name field when the picker is revealed by hand (not on
	// the empty home, where stealing focus would be presumptuous).
	useEffect(() => {
		if (open && !startOpen) inputRef.current?.focus();
	}, [open, startOpen]);

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

	return (
		<div
			data-testid="new-session-picker"
			className="animate-rise-fast"
			onKeyDown={(event) => {
				if (event.key === "Escape" && !startOpen) setOpen(false);
			}}
		>
			{repos.length > 0 && (
				<ul className="mb-1">
					{repos.map((repo) => (
						<li key={repo.id}>
							<form action={createSessionAction}>
								<input type="hidden" name="repo" value={repo.fullName} />
								<button
									type="submit"
									className="w-full rounded-md px-2.5 py-2 text-left font-mono text-[13px] text-item-ink transition-colors hover:bg-hover-bg hover:text-accent"
								>
									{repo.fullName}
								</button>
							</form>
						</li>
					))}
				</ul>
			)}
			<form
				action={createSessionAction}
				className="flex items-center gap-2.5 px-2.5 py-2"
			>
				<span aria-hidden className="font-mono text-[13px] text-accent">
					›
				</span>
				<input
					ref={inputRef}
					type="text"
					name="repo"
					required
					pattern="[A-Za-z0-9][A-Za-z0-9_.\-]*\/[A-Za-z0-9_.\-]+"
					title="owner/repository"
					aria-label="Repository (owner/name)"
					placeholder="owner/repository"
					autoComplete="off"
					spellCheck={false}
					className="min-w-0 flex-1 border-b border-line bg-transparent pb-1 font-mono text-[13px] text-ink transition-colors outline-none placeholder:text-faint focus:border-focus-line"
				/>
			</form>
		</div>
	);
}
