import type { TimelineEntry } from "./types";

const dayKeyCache = new Map<string, string>();

export function dayKey(timestamp: string): string {
	const cached = dayKeyCache.get(timestamp);
	if (cached) return cached;
	const value = new Date(timestamp).toLocaleDateString("en-US", {
		month: "short",
		day: "numeric",
	});
	dayKeyCache.set(timestamp, value);
	return value;
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
