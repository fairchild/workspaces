"use client";

import { useCallback, useEffect, useRef, useState } from "react";

export interface TerminalSessionInfo {
	agentName: string;
	state: "running" | "paused";
	sandboxId: string;
	provider: string;
	terminalUrl?: string;
}

interface StatusResponse {
	sessions: TerminalSessionInfo[];
}

export type ProvisioningState = "starting" | "resuming";

export interface UseTerminalSessions {
	sessions: TerminalSessionInfo[];
	provisioning: Record<string, ProvisioningState>;
	error: string | null;
	startTerminal: (agentName?: string) => Promise<string | null>;
	stopTerminal: (agentName: string) => Promise<void>;
	resumeTerminal: (agentName: string) => Promise<void>;
	refresh: () => Promise<void>;
}

const POLL_INTERVAL_MS = 10_000;
const PROVISIONING_POLL_MS = 1_000;
const PROVISIONING_MAX_POLLS = 20;

/**
 * Owns the terminal session state for one repo: polling, provisioning,
 * and the start/stop/resume mutations. The TerminalPanel uses this to
 * stay focused on rendering.
 */
export function useTerminalSessions(repo: string | null): UseTerminalSessions {
	const [sessions, setSessions] = useState<TerminalSessionInfo[]>([]);
	const [provisioning, setProvisioning] = useState<
		Record<string, ProvisioningState>
	>({});
	const [error, setError] = useState<string | null>(null);

	// Stable callback references to avoid re-creating on every render
	const repoRef = useRef(repo);
	useEffect(() => {
		repoRef.current = repo;
	}, [repo]);

	const refresh = useCallback(async () => {
		const r = repoRef.current;
		if (!r) {
			setSessions([]);
			return;
		}
		try {
			const res = await fetch(
				`/api/terminal/status?repo=${encodeURIComponent(r)}`,
			);
			if (res.ok) {
				const data: StatusResponse = await res.json();
				setSessions(data.sessions ?? []);
			}
		} catch {
			// silent — next poll will retry
		}
	}, []);

	// Poll the status API on a fixed interval
	useEffect(() => {
		refresh();
		const id = setInterval(refresh, POLL_INTERVAL_MS);
		return () => clearInterval(id);
	}, [refresh]);

	// Reset state when repo changes
	useEffect(() => {
		setSessions([]);
		setProvisioning({});
		setError(null);
	}, []);

	/**
	 * Provision a new sandbox. Optimistically marks the slot as provisioning,
	 * polls until it shows up in the sessions list (or timeout), then clears.
	 * Returns the slot name that was provisioned, or null on error.
	 */
	const startTerminal = useCallback(
		async (agentName?: string): Promise<string | null> => {
			const r = repoRef.current;
			if (!r) return null;
			const slot = agentName ?? "shell";
			if (provisioning[slot]) return slot;

			setProvisioning((p) => ({ ...p, [slot]: "starting" }));
			setError(null);

			try {
				const res = await fetch("/api/terminal/start", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ repo: r, agentName }),
				});
				if (!res.ok) {
					const body = await res.json().catch(() => ({}));
					setError(body.error ?? `HTTP ${res.status}`);
					return null;
				}
				const data = (await res.json()) as { agentName: string };
				// Poll until the new session shows up in the list
				for (let i = 0; i < PROVISIONING_MAX_POLLS; i++) {
					await new Promise((r) => setTimeout(r, PROVISIONING_POLL_MS));
					await refresh();
				}
				return data.agentName;
			} catch (err) {
				setError(err instanceof Error ? err.message : "Start failed");
				return null;
			} finally {
				setProvisioning((p) => {
					const next = { ...p };
					delete next[slot];
					return next;
				});
			}
		},
		[provisioning, refresh],
	);

	const resumeTerminal = useCallback(
		async (agentName: string): Promise<void> => {
			const r = repoRef.current;
			if (!r || provisioning[agentName]) return;
			setProvisioning((p) => ({ ...p, [agentName]: "resuming" }));
			setError(null);
			try {
				const res = await fetch("/api/terminal/resume", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ repo: r, agentName }),
				});
				if (!res.ok) {
					const body = await res.json().catch(() => ({}));
					setError(body.error ?? `HTTP ${res.status}`);
					return;
				}
				for (let i = 0; i < PROVISIONING_MAX_POLLS; i++) {
					await new Promise((r) => setTimeout(r, PROVISIONING_POLL_MS));
					await refresh();
				}
			} catch (err) {
				setError(err instanceof Error ? err.message : "Resume failed");
			} finally {
				setProvisioning((p) => {
					const next = { ...p };
					delete next[agentName];
					return next;
				});
			}
		},
		[provisioning, refresh],
	);

	const stopTerminal = useCallback(
		async (agentName: string): Promise<void> => {
			const r = repoRef.current;
			if (!r) return;
			try {
				await fetch("/api/terminal/stop", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ repo: r, agentName }),
				});
			} catch {
				// best-effort; refresh below
			}
			await refresh();
		},
		[refresh],
	);

	return {
		sessions,
		provisioning,
		error,
		startTerminal,
		stopTerminal,
		resumeTerminal,
		refresh,
	};
}
