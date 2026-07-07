"use client";

/*
 * Inline failure affordance for a turn that errored or was interrupted before
 * completion — quiet, typography-first, in the same faint-caption register as
 * TurnStatsReceipt (the receipt it replaces on a failed turn), no toast/alert
 * chrome. Guards against a double-fired retry itself (a click while the
 * request is still in flight): `retryDisabled` from the caller covers the
 * turn-level "another turn is already running" state, but there's a gap
 * between the click and that flag flipping true, so a local latch closes it.
 *
 * The latch is a ref, not state: two `handleRetry` calls from the same click
 * burst (e.g. a fast double-click, or React batching two events before a
 * re-render) both read `pendingRef.current` synchronously, so the second call
 * sees the first's write immediately — a `useState` flag would still show its
 * pre-click value to both, since neither call observes the other's `setState`
 * until the next render, and one render can't happen between two events fired
 * before it.
 */
import { useRef, useState } from "react";

export interface TurnFailureProps {
	/** The stream's error text, or the interrupted-turn fallback message. */
	message: string;
	/** Omitted when the turn's original text can't be recovered (rare). */
	onRetry?: () => void;
	/** Holds retry while another turn on this session is already running. */
	retryDisabled?: boolean;
}

export function TurnFailure({ message, onRetry, retryDisabled }: TurnFailureProps) {
	const pendingRef = useRef(false);
	// Mirrors pendingRef into render output (refs alone don't trigger one).
	const [pending, setPending] = useState(false);
	const disabled = retryDisabled || pending;

	const handleRetry = () => {
		if (retryDisabled || pendingRef.current || !onRetry) return;
		pendingRef.current = true;
		setPending(true);
		onRetry();
	};

	return (
		<div
			data-testid="turn-failure"
			className="mt-5 flex flex-wrap items-baseline gap-x-3 gap-y-1 font-mono text-stat tracking-[.04em] text-del-ink"
		>
			<span>{message}</span>
			{onRetry && (
				<button
					type="button"
					onClick={handleRetry}
					disabled={disabled}
					className="border-b border-transparent pb-px text-del-ink transition-colors duration-200 hover:border-del-ink disabled:cursor-default disabled:opacity-50 disabled:hover:border-transparent"
				>
					Retry
				</button>
			)}
		</div>
	);
}
