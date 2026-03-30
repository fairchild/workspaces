import type { TimelineEntry } from "./types";

export function dayKey(timestamp: string): string {
	return new Date(timestamp).toLocaleDateString("en-US", {
		month: "short",
		day: "numeric",
	});
}

export function shouldShowDay(
	entries: TimelineEntry[],
	index: number,
): boolean {
	if (index === 0) return true;
	const prev = entries[index - 1];
	const curr = entries[index];
	return dayKey(prev.timestamp) !== dayKey(curr.timestamp);
}
