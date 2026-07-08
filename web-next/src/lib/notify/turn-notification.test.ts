import { describe, expect, test, vi } from "vitest";
import {
	buildTurnNotificationPayload,
	notifyTurnCompleted,
	type TurnNotificationInput,
} from "./turn-notification";

const input: TurnNotificationInput = {
	session: {
		id: "session-1",
		repoId: "fairchild/workspaces",
		title: "Fix notifications",
	},
	outcome: "completed",
	durationMs: 42,
};

describe("buildTurnNotificationPayload", () => {
	test("includes the configured session URL when BETTER_AUTH_URL is set", () => {
		expect(
			buildTurnNotificationPayload(input, {
				BETTER_AUTH_URL: "https://spaces.example/",
			}),
		).toEqual({
			event: "turn_completed",
			sessionId: "session-1",
			title: "Fix notifications",
			repo: "fairchild/workspaces",
			outcome: "completed",
			durationMs: 42,
			url: "https://spaces.example/sessions/session-1",
		});
	});

	test("omits url and uses an empty repo when those fields are absent", () => {
		expect(
			buildTurnNotificationPayload({
				...input,
				session: { id: "session-2", repoId: null, title: "" },
			}),
		).toEqual({
			event: "turn_completed",
			sessionId: "session-2",
			title: "",
			repo: "",
			outcome: "completed",
			durationMs: 42,
		});
	});
});

describe("notifyTurnCompleted", () => {
	test("does nothing when WEB_NEXT_NOTIFY_URL is absent", async () => {
		const fetchImpl = vi.fn<typeof fetch>();
		await notifyTurnCompleted(input, { env: {}, fetch: fetchImpl });
		expect(fetchImpl).not.toHaveBeenCalled();
	});

	test("posts the payload and optional bearer token", async () => {
		const fetchImpl = vi.fn<typeof fetch>(async () => new Response("", { status: 204 }));

		await notifyTurnCompleted(input, {
			env: {
				BETTER_AUTH_URL: "https://spaces.example",
				WEB_NEXT_NOTIFY_TOKEN: "secret",
				WEB_NEXT_NOTIFY_URL: "https://hooks.example/turns",
			},
			fetch: fetchImpl,
		});

		expect(fetchImpl).toHaveBeenCalledWith(
			"https://hooks.example/turns",
			expect.objectContaining({
				body: JSON.stringify({
					event: "turn_completed",
					sessionId: "session-1",
					title: "Fix notifications",
					repo: "fairchild/workspaces",
					outcome: "completed",
					durationMs: 42,
					url: "https://spaces.example/sessions/session-1",
				}),
				headers: {
					authorization: "Bearer secret",
					"content-type": "application/json",
				},
				method: "POST",
			}),
		);
	});

	test("swallows a throwing endpoint", async () => {
		const error = new Error("network down");
		const logger = { error: vi.fn() };
		const fetchImpl = vi.fn<typeof fetch>(async () => {
			throw error;
		});

		await expect(
			notifyTurnCompleted(input, {
				env: { WEB_NEXT_NOTIFY_URL: "https://hooks.example/turns" },
				fetch: fetchImpl,
				logger,
			}),
		).resolves.toBeUndefined();
		expect(logger.error).toHaveBeenCalledWith(
			"[turn-notification] webhook delivery failed",
			error,
		);
	});

	test("bounds a hanging endpoint with the abort timeout", async () => {
		const logger = { error: vi.fn() };
		const fetchImpl = vi.fn<typeof fetch>(
			(_url, init) =>
				new Promise((_resolve, reject) => {
					init?.signal?.addEventListener("abort", () => {
						reject(new DOMException("aborted", "AbortError"));
					});
				}),
		);

		await expect(
			notifyTurnCompleted(input, {
				env: { WEB_NEXT_NOTIFY_URL: "https://hooks.example/turns" },
				fetch: fetchImpl,
				logger,
				timeoutMs: 1,
			}),
		).resolves.toBeUndefined();
		expect(logger.error).toHaveBeenCalledOnce();
	});
});
