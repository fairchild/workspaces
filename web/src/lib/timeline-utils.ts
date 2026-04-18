import type { TimelineEntry } from "./types";

const FORMAT_TTL = 30_000;
const dayKeyCache = new Map<string, string>();
const compactCache = new Map<string, { value: string; expires: number }>();
const relativeCache = new Map<string, { value: string; expires: number }>();

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
	const now = Date.now();
	const cached = compactCache.get(timestamp);
	if (cached && now < cached.expires) return cached.value;

	const diff = now - new Date(timestamp).getTime();
	const mins = Math.floor(diff / 60_000);
	let value: string;
	if (mins < 1) value = "now";
	else if (mins < 60) value = `${mins}m`;
	else {
		const hours = Math.floor(mins / 60);
		value = hours < 24 ? `${hours}h` : `${Math.floor(hours / 24)}d`;
	}

	compactCache.set(timestamp, { value, expires: now + FORMAT_TTL });
	return value;
}

export function formatRelativeTime(timestamp: string): string {
	const now = Date.now();
	const cached = relativeCache.get(timestamp);
	if (cached && now < cached.expires) return cached.value;

	const diff = now - new Date(timestamp).getTime();
	const mins = Math.floor(diff / 60_000);
	let value: string;
	if (mins < 1) value = "just now";
	else if (mins < 60) value = `${mins}m ago`;
	else {
		const hours = Math.floor(mins / 60);
		value = hours < 24 ? `${hours}h ago` : `${Math.floor(hours / 24)}d ago`;
	}

	relativeCache.set(timestamp, { value, expires: now + FORMAT_TTL });
	return value;
}
