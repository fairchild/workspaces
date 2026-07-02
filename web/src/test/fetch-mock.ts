/**
 * Minimal `fetch` mocking for dashboard component tests. Installs a
 * `vi.fn()` on `globalThis.fetch` that dispatches to a handler by matching
 * the request URL against an ordered list of string/RegExp routes — the
 * first match wins, so register more specific routes before broader ones
 * (e.g. a repo-scoped endpoint before a bare `/api/repos` fallback).
 *
 * Handlers can return a value synchronously or a Promise, so tests can wire
 * a route straight to a `deferred()` promise to control resolution order.
 */
import { vi } from "vitest";

type FetchHandler = (
	url: string,
	init?: RequestInit,
) => Response | Promise<Response>;

export type FetchRoute = [string | RegExp, FetchHandler];

export interface MockFetch {
	fn: ReturnType<typeof vi.fn>;
	restore: () => void;
}

/** Builds a minimal Response-like object matching what these components read (`.ok`, `.json()`). */
export function jsonResponse(
	data: unknown,
	init: { ok?: boolean; status?: number } = {},
): Response {
	const ok = init.ok ?? true;
	const status = init.status ?? (ok ? 200 : 500);
	return {
		ok,
		status,
		statusText: ok ? "OK" : "Error",
		json: async () => data,
	} as Response;
}

export function installFetchMock(
	routes: FetchRoute[],
	fallback: FetchHandler = () => jsonResponse({}),
): MockFetch {
	const original = globalThis.fetch;
	const fn = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
		const url = typeof input === "string" ? input : input.toString();
		const match = routes.find(([pattern]) =>
			typeof pattern === "string" ? url.includes(pattern) : pattern.test(url),
		);
		const handler = match ? match[1] : fallback;
		return Promise.resolve(handler(url, init));
	});
	globalThis.fetch = fn as unknown as typeof fetch;
	return {
		fn,
		restore: () => {
			globalThis.fetch = original;
		},
	};
}
