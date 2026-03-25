"use client";

import type { GitHubRepo, SelectedRepo } from "@/lib/types";
import { useRouter, useSearchParams } from "next/navigation";
import { Suspense, useCallback, useEffect, useMemo, useState } from "react";
import styles from "./page.module.css";

function formatRelativeTime(dateStr: string): string {
	const date = new Date(dateStr);
	const now = new Date();
	const diff = now.getTime() - date.getTime();
	const mins = Math.floor(diff / 60000);
	if (mins < 1) return "just now";
	if (mins < 60) return `${mins}m ago`;
	const hours = Math.floor(mins / 60);
	if (hours < 24) return `${hours}h ago`;
	const days = Math.floor(hours / 24);
	if (days < 30) return `${days}d ago`;
	const months = Math.floor(days / 30);
	return `${months}mo ago`;
}

const AGENT_BATCH_SIZE = 5;

function SetupInner() {
	const router = useRouter();
	const searchParams = useSearchParams();
	const isAddMode = searchParams.get("add") === "true";

	const [repos, setRepos] = useState<GitHubRepo[]>([]);
	const [selected, setSelected] = useState<Set<string>>(new Set());
	const [filter, setFilter] = useState("");
	const [loadingRepos, setLoadingRepos] = useState(true);
	const [submitting, setSubmitting] = useState(false);
	const [agentInfo, setAgentInfo] = useState<
		Map<string, { hasAgents: boolean; agentCount: number }>
	>(new Map());

	const [error, setError] = useState<string | null>(null);

	// Fetch GitHub repos
	useEffect(() => {
		(async () => {
			try {
				const res = await fetch("/api/github/repos");
				if (res.ok) {
					const data: GitHubRepo[] = await res.json();
					setRepos(data);
				} else {
					const body = await res.json().catch(() => ({}));
					setError(
						body.needsReauth
							? "Please sign out and sign back in to grant repository access."
							: `Failed to load repos: ${body.error ?? res.statusText}`,
					);
				}
			} catch {
				setError("Failed to connect to GitHub API");
			} finally {
				setLoadingRepos(false);
			}
		})();
	}, []);

	// In add mode, pre-check already-saved repos
	useEffect(() => {
		if (!isAddMode) return;
		(async () => {
			try {
				const res = await fetch("/api/repos");
				if (res.ok) {
					const saved: SelectedRepo[] = await res.json();
					setSelected(new Set(saved.map((r) => `${r.owner}/${r.repo}`)));
				}
			} catch {
				// Silently handle
			}
		})();
	}, [isAddMode]);

	// Lazy-load agent detection — only scan repos the user is likely to select (top 20)
	useEffect(() => {
		if (repos.length === 0) return;

		let cancelled = false;
		const toScan = repos.slice(0, 20);

		async function detectAgents() {
			for (let i = 0; i < toScan.length; i += AGENT_BATCH_SIZE) {
				if (cancelled) return;
				const batch = toScan.slice(i, i + AGENT_BATCH_SIZE);
				const results = await Promise.allSettled(
					batch.map(async (repo) => {
						try {
							const res = await fetch(
								`/api/repos/${repo.owner}/${repo.name}/agents`,
							);
							if (res.ok) {
								const data = await res.json();
								return {
									key: repo.full_name,
									hasAgents: (data.stats?.agentCount ?? 0) > 0,
									agentCount: data.stats?.agentCount ?? 0,
								};
							}
						} catch {
							// Skip repos that fail
						}
						return { key: repo.full_name, hasAgents: false, agentCount: 0 };
					}),
				);

				if (cancelled) return;

				setAgentInfo((prev) => {
					const next = new Map(prev);
					for (const result of results) {
						if (result.status === "fulfilled") {
							next.set(result.value.key, {
								hasAgents: result.value.hasAgents,
								agentCount: result.value.agentCount,
							});
						}
					}
					return next;
				});
			}
		}

		detectAgents();
		return () => {
			cancelled = true;
		};
	}, [repos]);

	const toggleRepo = useCallback((fullName: string) => {
		setSelected((prev) => {
			const next = new Set(prev);
			if (next.has(fullName)) {
				next.delete(fullName);
			} else {
				next.add(fullName);
			}
			return next;
		});
	}, []);

	const filtered = useMemo(() => {
		if (!filter) return repos;
		const lower = filter.toLowerCase();
		return repos.filter(
			(r) =>
				r.full_name.toLowerCase().includes(lower) ||
				(r.description?.toLowerCase().includes(lower) ?? false),
		);
	}, [repos, filter]);

	const handleContinue = useCallback(async () => {
		setSubmitting(true);
		try {
			const repoPayload = Array.from(selected).map((fullName) => {
				const [owner, repo] = fullName.split("/");
				return { owner, repo };
			});
			const res = await fetch("/api/repos", {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ repos: repoPayload }),
			});
			if (res.ok) {
				router.push("/dashboard");
			}
		} catch {
			// Silently handle
		} finally {
			setSubmitting(false);
		}
	}, [selected, router]);

	return (
		<main className={styles.main}>
			<div className={styles.gridMotif} aria-hidden="true">
				<div className={styles.gridCell} />
				<div className={styles.gridCell} />
				<div className={styles.gridCell} />
				<div className={`${styles.gridCell} ${styles.gridCellActive}`}>
					<span className={styles.gridChevron}>&gt;</span>
				</div>
			</div>

			<div className={styles.card}>
				<div className={styles.header}>
					<h1 className={styles.wordmark}>Spaces</h1>
					<p className={styles.subtitle}>
						{isAddMode
							? "Add repositories to your dashboard"
							: "Select repositories to monitor"}
					</p>
				</div>

				<div className={styles.filterWrap}>
					<input
						type="text"
						className={styles.filterInput}
						placeholder="Filter repositories..."
						value={filter}
						onChange={(e) => setFilter(e.target.value)}
					/>
				</div>

				{loadingRepos ? (
					<div className={styles.loading}>
						<span className={styles.loadingDot} />
						<span className={styles.loadingText}>Loading repositories...</span>
					</div>
				) : error ? (
					<div className={styles.empty}>
						<span className={styles.emptyText}>{error}</span>
					</div>
				) : filtered.length === 0 ? (
					<div className={styles.empty}>
						<span className={styles.emptyText}>
							{filter
								? "No repositories match your filter"
								: "No repositories found"}
						</span>
					</div>
				) : (
					<div className={styles.repoList}>
						{filtered.map((repo) => {
							const isSelected = selected.has(repo.full_name);
							const info = agentInfo.get(repo.full_name);
							return (
								<label
									key={repo.full_name}
									className={`${styles.repoRow} ${isSelected ? styles.repoRowSelected : ""}`}
								>
									<input
										type="checkbox"
										checked={isSelected}
										onChange={() => toggleRepo(repo.full_name)}
										className={styles.hiddenCheckbox}
									/>
									<div
										className={`${styles.checkbox} ${isSelected ? styles.checkboxChecked : ""}`}
									>
										{isSelected && (
											<span className={styles.checkmark}>&#10003;</span>
										)}
									</div>
									<div className={styles.repoInfo}>
										<div className={styles.repoNameRow}>
											<span className={styles.repoName}>{repo.full_name}</span>
											{info?.hasAgents && (
												<span className={styles.agentBadge}>
													{info.agentCount} agent
													{info.agentCount !== 1 ? "s" : ""}
												</span>
											)}
										</div>
										{repo.description && (
											<span className={styles.repoDesc}>
												{repo.description}
											</span>
										)}
									</div>
									<div className={styles.repoMeta}>
										<span className={styles.repoTime}>
											{formatRelativeTime(repo.pushed_at)}
										</span>
									</div>
								</label>
							);
						})}
					</div>
				)}

				<div className={styles.bottomBar}>
					<span className={styles.selectedCount}>{selected.size} selected</span>
					<button
						type="button"
						className={styles.continueButton}
						disabled={selected.size === 0 || submitting}
						onClick={handleContinue}
					>
						<span>
							{submitting
								? "Saving..."
								: `Continue with ${selected.size} repo${selected.size !== 1 ? "s" : ""}`}
						</span>
						<span className={styles.continueChevron}>&gt;</span>
					</button>
				</div>
			</div>
		</main>
	);
}

export default function SetupPage() {
	return (
		<Suspense>
			<SetupInner />
		</Suspense>
	);
}
