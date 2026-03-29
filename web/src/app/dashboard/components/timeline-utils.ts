export function formatTime(timestamp: string): string {
	const diff = Date.now() - new Date(timestamp).getTime();
	const mins = Math.floor(diff / 60000);
	if (mins < 1) return "now";
	if (mins < 60) return `${mins}m`;
	const hours = Math.floor(mins / 60);
	if (hours < 24) return `${hours}h`;
	return `${Math.floor(hours / 24)}d`;
}
