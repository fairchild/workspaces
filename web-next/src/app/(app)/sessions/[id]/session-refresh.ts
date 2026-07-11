/*
 * Bounded session-snapshot reconciliation for live turn transitions. A turn
 * can finish while one request or one server instance is transiently failing;
 * retrying the durable read keeps page state convergent without an unbounded
 * poller or a second source of truth in the stream protocol.
 */

const DEFAULT_ATTEMPTS = 3;
const RETRY_BASE_MS = 250;

export async function fetchSessionSnapshotWithRetry<T>(
	url: string,
	options: {
		attempts?: number;
		fetcher?: typeof fetch;
		sleep?: (milliseconds: number) => Promise<void>;
	} = {},
): Promise<T | null> {
	const attempts = Math.max(1, options.attempts ?? DEFAULT_ATTEMPTS);
	const fetcher = options.fetcher ?? fetch;
	const sleep =
		options.sleep ??
		((milliseconds: number) =>
			new Promise<void>((resolve) => setTimeout(resolve, milliseconds)));

	for (let attempt = 0; attempt < attempts; attempt += 1) {
		try {
			const response = await fetcher(url);
			if (response.ok) return (await response.json()) as T;
		} catch {
			// A rejected fetch and an invalid JSON response are both transient from
			// this reconciliation seam; retry below, then leave current UI intact.
		}
		if (attempt + 1 < attempts) {
			await sleep(RETRY_BASE_MS * 2 ** attempt);
		}
	}
	return null;
}
