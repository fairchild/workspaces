/**
 * Regression coverage for a real bug class: ActivityFeed polls
 * `/api/events` on an interval, keyed by `filterRepo`. Switching
 * `filterRepo` used to risk a stale in-flight poll response (from the
 * previous repo filter) landing after the switch and rendering the wrong
 * repo's events. The fix re-runs the fetch effect with a fresh per-request
 * `cancelled` flag whenever `filterRepo` changes. This test resolves the
 * *old* filter's request *after* the *new* filter's request and asserts the
 * stale data never renders.
 */
import type { WebhookEvent } from "@/lib/types";
import { deferred } from "@/test/deferred";
import { installFetchMock, jsonResponse } from "@/test/fetch-mock";
import { act, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ActivityFeed } from "../activity-feed";

function makeEvent(id: string, summary: string, repo: string): WebhookEvent {
	return {
		id,
		type: "push",
		action: "push",
		summary,
		repo,
		timestamp: new Date().toISOString(),
	};
}

describe("ActivityFeed filterRepo switch", () => {
	it("does not let a stale poll result from the old filter win", async () => {
		const oldFilterDeferred = deferred<WebhookEvent[]>();
		const newFilterDeferred = deferred<WebhookEvent[]>();

		const mock = installFetchMock([
			[
				"repo=acme%2Frepo-a",
				() => oldFilterDeferred.promise.then((data) => jsonResponse(data)),
			],
			[
				"repo=acme%2Frepo-b",
				() => newFilterDeferred.promise.then((data) => jsonResponse(data)),
			],
		]);

		const { rerender } = render(<ActivityFeed filterRepo="acme/repo-a" />);

		// Switch the filter before repo-a's request resolves — this is the race.
		rerender(<ActivityFeed filterRepo="acme/repo-b" />);

		await act(async () => {
			newFilterDeferred.resolve([makeEvent("evt-b", "Event B", "acme/repo-b")]);
			await Promise.resolve();
			await Promise.resolve();
		});
		expect(await screen.findByText("Event B")).not.toBeNull();

		// The stale repo-a request resolves after the switch — must not win.
		await act(async () => {
			oldFilterDeferred.resolve([makeEvent("evt-a", "Event A", "acme/repo-a")]);
			await new Promise((resolve) => setTimeout(resolve, 0));
		});

		expect(screen.queryByText("Event A")).toBeNull();
		expect(screen.getByText("Event B")).not.toBeNull();

		mock.restore();
	});
});
