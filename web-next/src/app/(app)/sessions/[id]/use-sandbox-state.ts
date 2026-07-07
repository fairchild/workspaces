"use client";

/*
 * Client view of the session's sandbox state (#753): fetches the truthful
 * verdict from GET /api/sessions/[id]/sandbox and keeps it honest over time —
 * re-checked when a turn settles (the moment a sandbox is born or parked),
 * on window focus, and on a slow interval while a VM exists (sandboxes
 * expire on their own; a "live" label must not outlive the VM). `null`
 * means not-yet-known, which the masthead renders as absence, not a guess.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import type { SandboxState } from "@/lib/agent-runtime/sandbox-state";

/** How often a known live/parked state is re-verified against the platform. */
const REFRESH_INTERVAL_MS = 60_000;

export function useSandboxState(sessionId: string, turnInFlight: boolean) {
	const [sandbox, setSandbox] = useState<SandboxState | null>(null);

	const refresh = useCallback(async () => {
		try {
			const res = await fetch(`/api/sessions/${sessionId}/sandbox`);
			if (!res.ok) return;
			const data = (await res.json()) as SandboxState;
			if (data && typeof data.state === "string") setSandbox(data);
		} catch {
			// Network hiccup: keep the last verified state rather than flapping.
		}
	}, [sessionId]);

	// Known on arrival, re-verified whenever the tab comes back into focus.
	useEffect(() => {
		void refresh();
		const onFocus = () => void refresh();
		window.addEventListener("focus", onFocus);
		return () => window.removeEventListener("focus", onFocus);
	}, [refresh]);

	// A turn settling is exactly when the sandbox changes hands (born on the
	// first vercel turn, parked by detach) — re-check at that edge.
	const wasInFlight = useRef(turnInFlight);
	useEffect(() => {
		if (wasInFlight.current && !turnInFlight) void refresh();
		wasInFlight.current = turnInFlight;
	}, [turnInFlight, refresh]);

	// While a VM exists, its 30-minute lifetime can lapse under an idle tab.
	useEffect(() => {
		if (sandbox?.state !== "live" && sandbox?.state !== "parked") return;
		const timer = setInterval(() => void refresh(), REFRESH_INTERVAL_MS);
		return () => clearInterval(timer);
	}, [sandbox?.state, refresh]);

	const stopSandbox = useCallback(async () => {
		try {
			const res = await fetch(`/api/sessions/${sessionId}/sandbox`, {
				method: "DELETE",
			});
			if (!res.ok) return;
			const data = (await res.json()) as SandboxState;
			if (data && typeof data.state === "string") setSandbox(data);
		} catch {
			// The next refresh re-verifies; the label never claims the stop worked.
		}
	}, [sessionId]);

	return { sandbox, stopSandbox };
}

/** The masthead's quiet phrasing for each verified state ("" = not yet known). */
export function sandboxStateLabel(sandbox: SandboxState | null): string {
	if (!sandbox) return "";
	if (sandbox.state === "live") return "sandbox live";
	if (sandbox.state === "parked") return "sandbox parked";
	return "no sandbox";
}
