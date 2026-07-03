/*
 * Quiet recency labels for the sessions home ("just now", "4m ago",
 * "Jun 12"). Server-rendered; coarse buckets on purpose so the page does
 * not need a ticking client clock.
 */

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

const MONTHS = [
	"Jan",
	"Feb",
	"Mar",
	"Apr",
	"May",
	"Jun",
	"Jul",
	"Aug",
	"Sep",
	"Oct",
	"Nov",
	"Dec",
];

export function formatRelativeTime(iso: string, now: Date = new Date()): string {
	const then = new Date(iso);
	const elapsed = now.getTime() - then.getTime();
	if (Number.isNaN(elapsed)) return "";
	if (elapsed < MINUTE) return "just now";
	if (elapsed < HOUR) return `${Math.floor(elapsed / MINUTE)}m ago`;
	if (elapsed < DAY) return `${Math.floor(elapsed / HOUR)}h ago`;
	if (elapsed < 7 * DAY) return `${Math.floor(elapsed / DAY)}d ago`;
	const date = `${MONTHS[then.getUTCMonth()]} ${then.getUTCDate()}`;
	return then.getUTCFullYear() === now.getUTCFullYear()
		? date
		: `${date} ${then.getUTCFullYear()}`;
}
