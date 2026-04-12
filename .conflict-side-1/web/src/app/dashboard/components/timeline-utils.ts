const FORMAT_TTL = 30_000;
const formatCache = new Map<string, { value: string; expires: number }>();

export function formatTime(timestamp: string): string {
	const now = Date.now();
	const cached = formatCache.get(timestamp);
	if (cached && now < cached.expires) return cached.value;

	const diff = now - new Date(timestamp).getTime();
	const mins = Math.floor(diff / 60000);
	let value: string;
	if (mins < 1) value = "now";
	else if (mins < 60) value = `${mins}m`;
	else {
		const hours = Math.floor(mins / 60);
		value = hours < 24 ? `${hours}h` : `${Math.floor(hours / 24)}d`;
	}

	formatCache.set(timestamp, { value, expires: now + FORMAT_TTL });
	return value;
}
