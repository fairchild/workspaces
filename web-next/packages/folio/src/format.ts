/**
 * Pure, server-safe formatting helpers shared by Folio and its hosts.
 * Keep this entry free of React components and browser side effects.
 */

/** "820" / "3.2k" — used by token receipts and context figures. */
export function formatTokenCount(count: number): string {
	if (count < 1000) return String(count);
	return `${(count / 1000).toFixed(1).replace(/\.0$/, "")}k`;
}
