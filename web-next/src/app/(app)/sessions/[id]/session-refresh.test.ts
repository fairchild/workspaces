import { describe, expect, test, vi } from "vitest";
import { fetchSessionSnapshotWithRetry } from "./session-refresh";

describe("fetchSessionSnapshotWithRetry", () => {
	test("retries a transient non-OK completion snapshot", async () => {
		const fetcher = vi
			.fn<typeof fetch>()
			.mockResolvedValueOnce(new Response("unavailable", { status: 503 }))
			.mockResolvedValueOnce(
				Response.json({ session: { hasBranchWork: true } }),
			);
		const sleep = vi.fn(async () => undefined);

		const snapshot = await fetchSessionSnapshotWithRetry<{
			session: { hasBranchWork: boolean };
		}>("/api/sessions/session-123", { fetcher, sleep });

		expect(snapshot).toEqual({ session: { hasBranchWork: true } });
		expect(fetcher).toHaveBeenCalledTimes(2);
		expect(sleep).toHaveBeenCalledWith(250);
	});

	test("retries rejected fetches but remains bounded", async () => {
		const fetcher = vi.fn<typeof fetch>().mockRejectedValue(new Error("offline"));
		const sleep = vi.fn(async () => undefined);

		await expect(
			fetchSessionSnapshotWithRetry("/api/sessions/session-123", {
				attempts: 3,
				fetcher,
				sleep,
			}),
		).resolves.toBeNull();
		expect(fetcher).toHaveBeenCalledTimes(3);
		expect(sleep).toHaveBeenNthCalledWith(1, 250);
		expect(sleep).toHaveBeenNthCalledWith(2, 500);
	});
});
