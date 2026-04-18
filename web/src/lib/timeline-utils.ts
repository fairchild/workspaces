import type { TimelineEntry } from "./types";

const FORMAT_TTL = 30_000;
const dayKeyCache = new Map<string, string>();
const compactCache = new Map<string, { value: string; expires: number }>();
const relativeCache = new Map<string, { value: string; expires: number }>();

function getElapsedMinutes(timestamp: string, now: number): number {
	return Math.floor((now - new Date(timestamp).getTime()) / 60_000);
}

function formatElapsedTime(
	timestamp: string,
	cache: Map<string, { value: string; expires: number }>,
	formatValue: (mins: number) => string,
): string {
	const now = Date.now();
	const cached = cache.get(timestamp);
	if (cached && now < cached.expires) return cached.value;

	const value = formatValue(getElapsedMinutes(timestamp, now));
	cache.set(timestamp, { value, expires: now + FORMAT_TTL });
	return value;
}

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

export function formatCompactTime(timestamp: string): string {
	return formatElapsedTime(timestamp, compactCache, (mins) => {
		if (mins < 1) return "now";
		if (mins < 60) return `${mins}m`;
		const hours = Math.floor(mins / 60);
		return hours < 24 ? `${hours}h` : `${Math.floor(hours / 24)}d`;
	});
}

export function formatRelativeTime(timestamp: string): string {
	return formatElapsedTime(timestamp, relativeCache, (mins) => {
		if (mins < 1) return "just now";
		if (mins < 60) return `${mins}m ago`;
		const hours = Math.floor(mins / 60);
		return hours < 24 ? `${hours}h ago` : `${Math.floor(hours / 24)}d ago`;
	});
}
