"use client";

/*
 * Keyboard-first sessions-home list: a quiet filter strip plus visible row
 * selection. The server owns the data query; this component only reflects
 * controls into URL params and opens the selected session.
 */
import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import {
	type KeyboardEvent,
	useCallback,
	useEffect,
	useMemo,
	useRef,
	useState,
} from "react";
import type {
	SessionListFilterOptions,
	SessionListItem,
} from "@/lib/db/sessions";
import { formatRelativeTime } from "@/lib/relative-time";
import { NewSession } from "./new-session";

interface SessionsHomeListProps {
	sessions: SessionListItem[];
	filters: SessionListFilterOptions;
	initialQuery: string;
	initialRepoId: string;
	initialStatus: string;
}

function isTextInput(target: EventTarget | null): boolean {
	if (!(target instanceof HTMLElement)) return false;
	const tag = target.tagName.toLowerCase();
	return (
		tag === "input" ||
		tag === "textarea" ||
		tag === "select" ||
		target.isContentEditable
	);
}

/** Enter must stay with a focused control (button, link, …), not open a row. */
function isInteractive(target: EventTarget | null): boolean {
	if (!(target instanceof HTMLElement)) return false;
	return target.closest("a, button, [role='button'], summary") !== null;
}

function SessionRow({
	session,
	index,
	selected,
	onSelect,
}: {
	session: SessionListItem;
	index: number;
	selected: boolean;
	onSelect: () => void;
}) {
	return (
		<li
			className="animate-rise border-b border-line"
			style={index < 6 ? { animationDelay: `${0.03 + index * 0.05}s` } : undefined}
		>
			<Link
				href={`/sessions/${session.id}`}
				data-selected={selected ? "true" : undefined}
				onMouseEnter={onSelect}
				className="group block rounded-md px-2.5 py-[16px] outline-none transition-colors hover:bg-hover-bg focus-visible:bg-selected-bg data-[selected=true]:bg-selected-bg"
			>
				{session.title ? (
					<span className="font-serif text-body text-ink transition-colors group-hover:text-accent group-focus-visible:text-accent">
						{session.title}
					</span>
				) : (
					<span className="font-serif text-body text-hint italic transition-colors group-hover:text-accent group-focus-visible:text-accent">
						Untitled session
					</span>
				)}
				<span className="mt-1 flex flex-wrap items-baseline gap-[9px] font-mono text-caption text-muted">
					{session.repoFullName ?? "no repository"}
					<span className="text-faint">·</span>
					{formatRelativeTime(session.lastActivityAt)}
					{session.status !== "active" && (
						<>
							<span className="text-faint">·</span>
							<span className="text-hint">{session.status}</span>
						</>
					)}
				</span>
			</Link>
		</li>
	);
}

export function SessionsHomeList({
	sessions,
	filters,
	initialQuery,
	initialRepoId,
	initialStatus,
}: SessionsHomeListProps) {
	const router = useRouter();
	const pathname = usePathname();
	const searchParams = useSearchParams();
	const searchRef = useRef<HTMLInputElement>(null);
	const [query, setQuery] = useState(initialQuery);
	const [selectedIndex, setSelectedIndex] = useState(sessions.length > 0 ? 0 : -1);

	// Sync from the URL only while the user isn't mid-keystroke: an older
	// debounced replace's RSC payload must not clobber newer typed input.
	useEffect(() => {
		if (document.activeElement === searchRef.current) return;
		setQuery(initialQuery);
	}, [initialQuery]);
	useEffect(() => {
		setSelectedIndex((current) => {
			if (sessions.length === 0) return -1;
			if (current < 0) return 0;
			return Math.min(current, sessions.length - 1);
		});
	}, [sessions.length]);

	const replaceParams = useCallback(
		(next: { q?: string; repo?: string; status?: string }) => {
			const params = new URLSearchParams(searchParams);
			// Local query state rides along on every change, so a filter picked
			// before the search debounce fires can't drop the pending text.
			for (const [key, value] of Object.entries({ q: query.trim(), ...next })) {
				if (value) params.set(key, value);
				else params.delete(key);
			}
			const suffix = params.toString();
			router.replace(suffix ? `${pathname}?${suffix}` : pathname, { scroll: false });
		},
		[pathname, query, router, searchParams],
	);

	useEffect(() => {
		const handle = window.setTimeout(() => {
			if (query !== initialQuery) replaceParams({ q: query.trim() });
		}, 120);
		return () => window.clearTimeout(handle);
	}, [initialQuery, query, replaceParams]);

	const openSelected = useCallback(() => {
		const selected = sessions[selectedIndex];
		if (selected) router.push(`/sessions/${selected.id}`);
	}, [router, selectedIndex, sessions]);

	useEffect(() => {
		const onKeyDown = (event: globalThis.KeyboardEvent) => {
			if (isTextInput(event.target)) return;
			if (event.key === "/") {
				event.preventDefault();
				searchRef.current?.focus();
				searchRef.current?.select();
				return;
			}
			if (event.key === "ArrowDown" && sessions.length > 0) {
				event.preventDefault();
				setSelectedIndex((current) => Math.min(current + 1, sessions.length - 1));
				return;
			}
			if (event.key === "ArrowUp" && sessions.length > 0) {
				event.preventDefault();
				setSelectedIndex((current) => Math.max(current - 1, 0));
				return;
			}
			if (event.key === "Enter" && !isInteractive(event.target)) {
				openSelected();
			}
		};
		window.addEventListener("keydown", onKeyDown);
		return () => window.removeEventListener("keydown", onKeyDown);
	}, [openSelected, sessions.length]);

	const resultLabel = useMemo(() => {
		if (sessions.length === 1) return "1 session";
		return `${sessions.length} sessions`;
	}, [sessions.length]);

	function onSearchKeyDown(event: KeyboardEvent<HTMLInputElement>) {
		if (event.key === "ArrowDown" && sessions.length > 0) {
			event.preventDefault();
			setSelectedIndex((current) => Math.min(current + 1, sessions.length - 1));
		}
		if (event.key === "ArrowUp" && sessions.length > 0) {
			event.preventDefault();
			setSelectedIndex((current) => Math.max(current - 1, 0));
		}
		if (event.key === "Enter") {
			event.preventDefault();
			openSelected();
		}
	}

	return (
		<>
			<div className="mb-2 flex flex-wrap items-center gap-x-3 gap-y-2 px-2.5 font-mono text-caption text-hint">
				<label className="flex min-w-[210px] flex-1 items-center gap-2 border-b border-line py-1 transition-colors focus-within:border-focus-line">
					<span aria-hidden className="text-faint">
						/
					</span>
					<input
						ref={searchRef}
						type="search"
						value={query}
						onChange={(event) => setQuery(event.target.value)}
						onKeyDown={onSearchKeyDown}
						aria-label="Search sessions"
						placeholder="search sessions"
						spellCheck={false}
						className="min-w-0 flex-1 bg-transparent font-mono text-caption text-ink outline-none placeholder:text-hint"
					/>
				</label>
				<select
					aria-label="Filter by repository"
					value={initialRepoId}
					onChange={(event) => replaceParams({ repo: event.target.value })}
					className="max-w-[210px] bg-transparent font-mono text-caption text-hint outline-none hover:text-accent focus:text-accent"
				>
					<option value="">all repos</option>
					{filters.repos.map((repo) => (
						<option key={repo.value} value={repo.value}>
							{repo.label} ({repo.count})
						</option>
					))}
				</select>
				<select
					aria-label="Filter by state"
					value={initialStatus}
					onChange={(event) => replaceParams({ status: event.target.value })}
					className="bg-transparent font-mono text-caption text-hint outline-none hover:text-accent focus:text-accent"
				>
					<option value="">all states</option>
					{filters.statuses.map((status) => (
						<option key={status.value} value={status.value}>
							{status.label} ({status.count})
						</option>
					))}
				</select>
				<span className="ml-auto text-faint">{resultLabel}</span>
			</div>
			{sessions.length > 0 ? (
				<ul>
					{sessions.map((session, index) => (
						<SessionRow
							key={session.id}
							session={session}
							index={index}
							selected={index === selectedIndex}
							onSelect={() => setSelectedIndex(index)}
						/>
					))}
				</ul>
			) : (
				<p className="px-2.5 py-10 font-serif text-body text-muted italic">
					No matching sessions.
				</p>
			)}
			{/* The list ends in a quiet invitation, not a persistent button. */}
			<div className="mt-4 px-2.5">
				<NewSession />
			</div>
		</>
	);
}
