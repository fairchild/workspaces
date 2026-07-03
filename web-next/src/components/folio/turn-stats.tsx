/*
 * End-of-turn receipt: a faint one-line tally under completed agent turns.
 */
import { formatTurnStats } from "./ledger";
import type { TurnStatsData } from "./types";

export function TurnStatsReceipt({ stats }: { stats: TurnStatsData }) {
	return (
		<div
			data-testid="turn-stats"
			className="mt-5 font-mono text-stat tracking-[.04em] text-faint opacity-[.82]"
		>
			{formatTurnStats(stats)}
		</div>
	);
}
