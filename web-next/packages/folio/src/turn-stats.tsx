/*
 * End-of-turn receipt: a quiet one-line tally under completed agent turns.
 */
import { formatTurnStats } from "./ledger";
import type { TurnStatsData } from "./types";

export function TurnStatsReceipt({ stats }: { stats: TurnStatsData }) {
	return (
		<div
			data-testid="turn-stats"
			// text-hint carries the "quiet" weight on its own (#806) — an extra
			// opacity multiply on top of it would blend the readable tally back
			// below AA, so the token replaces the opacity rather than layering
			// under it.
			className="mt-5 font-mono text-stat tracking-[.04em] text-hint"
		>
			{formatTurnStats(stats)}
		</div>
	);
}
