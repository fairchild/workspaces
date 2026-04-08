"use client";

import { useCallback, useEffect, useState } from "react";

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
	refresh: () => Promise<TerminalSessionInfo[]>;
}

const POLL_INTERVAL_MS = 10_000;
const PROVISIONING_POLL_MS = 1_000;
const PROVISIONING_MAX_POLLS = 20;

/**
 * Owns the terminal session state for one repo: polling, provisioning,
 * and the start/stop/resume mutations. The TerminalPanel uses this to
 * stay focused on rendering.
 *
 * All callbacks close over `repo`, so changing repo invalidates them and
 * the polling effect re-runs with the new value. State is reset on the
 * same edge so the user never sees stale sessions from the previous repo.
 */
export function useTerminalSessions(repo: string | null): UseTerminalSessions {
	const [sessions, setSessions] = useState<TerminalSessionInfo[]>([]);
	const [provisioning, setProvisioning] = useState<
		Record<string, ProvisioningState>
	>({});
	const [error, setError] = useState<string | null>(null);

	const refresh = useCallback(async (): Promise<TerminalSessionInfo[]> => {
		if (!repo) {
			setSessions([]);
			return [];
		}
		try {
			const res = await fetch(
				`/api/terminal/status?repo=${encodeURIComponent(repo)}`,
			);
			if (res.ok) {
				const data: StatusResponse = await res.json();
				const list = data.sessions ?? [];
				setSessions(list);
				return list;
			}
		} catch {
			// silent — next poll will retry
		}
		return [];
	}, [repo]);

	// Poll the status API on a fixed interval. When repo changes, refresh
	// gets a new identity and this effect re-runs: blank state, fetch fresh,
	// and start a new interval pinned to the new repo.
	useEffect(() => {
		setSessions([]);
		setProvisioning({});
		setError(null);
		refresh();
		const id = setInterval(refresh, POLL_INTERVAL_MS);
		return () => clearInterval(id);
	}, [refresh]);

	const clearProvisioning = useCallback((slot: string) => {
		setProvisioning((p) => {
			const next = { ...p };
			delete next[slot];
			return next;
		});
	}, []);

	/**
	 * Background poll: refreshes the sessions list until the named slot
	 * appears as running, or until we hit the timeout. Always clears the
	 * provisioning state at the end so the UI doesn't get stuck.
	 *
	 * This MUST run outside the click handler — awaiting a 20s loop inside
	 * a button onClick blocks React's render cycle and triggers an INP
	 * warning ("Event handlers blocked UI updates for 47s"). Spawn it with
	 * `void pollUntilReady(...)` so the click handler can return immediately
	 * and the provisioning placeholder renders right away.
	 */
	const pollUntilReady = useCallback(
		async (slot: string): Promise<void> => {
			try {
				for (let i = 0; i < PROVISIONING_MAX_POLLS; i++) {
					await new Promise((r) => setTimeout(r, PROVISIONING_POLL_MS));
					const list = await refresh();
					const found = list.find((s) => s.agentName === slot);
					if (found && found.state === "running" && found.terminalUrl) {
						return;
					}
				}
			} finally {
				clearProvisioning(slot);
			}
		},
		[refresh, clearProvisioning],
	);

	/**
	 * Provision a new sandbox. Optimistically marks the slot as provisioning,
	 * fires the start request, and spawns a background poll to clear the
	 * provisioning state once the session shows up. Returns the slot name
	 * that was provisioned, or null on error.
	 */
	const startTerminal = useCallback(
		async (agentName?: string): Promise<string | null> => {
			if (!repo) return null;
			const slot = agentName ?? "shell";
			if (provisioning[slot]) return slot;

			setProvisioning((p) => ({ ...p, [slot]: "starting" }));
			setError(null);

			let data: { agentName: string };
			try {
				const res = await fetch("/api/terminal/start", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ repo, agentName }),
				});
				if (!res.ok) {
					const body = await res.json().catch(() => ({}));
					setError(body.error ?? `HTTP ${res.status}`);
					clearProvisioning(slot);
					return null;
				}
				data = (await res.json()) as { agentName: string };
			} catch (err) {
				setError(err instanceof Error ? err.message : "Start failed");
				clearProvisioning(slot);
				return null;
			}

			// Fire-and-forget — don't block the click handler on the poll loop.
			void pollUntilReady(slot);
			return data.agentName;
		},
		[repo, provisioning, pollUntilReady, clearProvisioning],
	);

	const resumeTerminal = useCallback(
		async (agentName: string): Promise<void> => {
			if (!repo || provisioning[agentName]) return;
			setProvisioning((p) => ({ ...p, [agentName]: "resuming" }));
			setError(null);
			try {
				const res = await fetch("/api/terminal/resume", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ repo, agentName }),
				});
				if (!res.ok) {
					const body = await res.json().catch(() => ({}));
					setError(body.error ?? `HTTP ${res.status}`);
					clearProvisioning(agentName);
					return;
				}
			} catch (err) {
				setError(err instanceof Error ? err.message : "Resume failed");
				clearProvisioning(agentName);
				return;
			}

			// Fire-and-forget — same reasoning as startTerminal.
			void pollUntilReady(agentName);
		},
		[repo, provisioning, pollUntilReady, clearProvisioning],
	);

	const stopTerminal = useCallback(
		async (agentName: string): Promise<void> => {
			if (!repo) return;
			try {
				await fetch("/api/terminal/stop", {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ repo, agentName }),
				});
			} catch {
				// best-effort; refresh below
			}
			await refresh();
		},
		[repo, refresh],
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
