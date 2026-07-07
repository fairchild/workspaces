"use client";

/*
 * Client view of the session's sandbox state (#753): fetches the truthful
 * verdict from GET /api/sessions/[id]/sandbox and keeps it honest over time —
 * re-checked on window focus, on a short cadence WHILE a turn runs (the turn
 * is what births the VM, so "no sandbox" must not persist across a running
 * turn), at the settle edge (detach parks it), and on a slow interval while
 * a VM exists (sandboxes expire on their own; a "live" label must not
 * outlive the VM). A verdict that can no longer be re-verified degrades to
 * `null` — not-yet-known — which the masthead renders as absence, not a
 * guess kept on display.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import type { SandboxState } from "@/lib/agent-runtime/sandbox-state";

/** How often a known live/parked state is re-verified against the platform. */
const REFRESH_INTERVAL_MS = 60_000;

/** Re-check cadence while a turn is in flight (the VM's birth window). */
const IN_TURN_REFRESH_MS = 10_000;

/** Consecutive failed checks after which the last verdict stops being shown. */
const MAX_STALE_CHECKS = 2;

export function useSandboxState(sessionId: string, turnInFlight: boolean) {
	const [sandbox, setSandbox] = useState<SandboxState | null>(null);

	// Monotonic fetch ordering: only the NEWEST in-flight check may write the
	// state. Without this, a slow earlier GET resolving after a fast later one
	// would overwrite the fresher verdict with a stale one — exactly the lie
	// this surface exists to avoid.
	const fetchSeq = useRef(0);
	// Consecutive checks that couldn't produce a verdict. One blip keeps the
	// last verified state (no flapping); past MAX_STALE_CHECKS the verdict is
	// no longer trustworthy and recedes to absence rather than staying up as
	// a claim nothing can back (codex finding, gpt-5.5 xhigh).
	const staleChecks = useRef(0);
	const refresh = useCallback(async () => {
		const seq = ++fetchSeq.current;
		const failed = () => {
			if (seq !== fetchSeq.current) return;
			staleChecks.current += 1;
			if (staleChecks.current >= MAX_STALE_CHECKS) setSandbox(null);
		};
		try {
			const res = await fetch(`/api/sessions/${sessionId}/sandbox`);
			if (seq !== fetchSeq.current) return;
			if (!res.ok) {
				failed();
				return;
			}
			const data = (await res.json()) as SandboxState;
			if (seq !== fetchSeq.current) return;
			if (data && typeof data.state === "string") {
				staleChecks.current = 0;
				setSandbox(data);
			}
		} catch {
			failed();
		}
	}, [sessionId]);

	// Known on arrival, re-verified whenever the tab comes back into focus.
	useEffect(() => {
		void refresh();
		const onFocus = () => void refresh();
		window.addEventListener("focus", onFocus);
		return () => window.removeEventListener("focus", onFocus);
	}, [refresh]);

	// A running turn is what births the VM (the first vercel turn boots it
	// seconds in, minutes before it settles), so the label must follow DURING
	// the turn, not only at its edges: re-check on entry, on a short cadence
	// while in flight, and once more at the settle edge (detach parks it).
	const wasInFlight = useRef(turnInFlight);
	useEffect(() => {
		if (wasInFlight.current && !turnInFlight) void refresh();
		wasInFlight.current = turnInFlight;
		if (!turnInFlight) return;
		void refresh();
		const timer = setInterval(() => void refresh(), IN_TURN_REFRESH_MS);
		return () => clearInterval(timer);
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
