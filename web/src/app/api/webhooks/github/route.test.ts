import crypto from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	getChatMessageByDiscussionId: vi.fn(),
	pushChatMessage: vi.fn(),
	pushEvent: vi.fn(),
	updateChatMessageContent: vi.fn(),
}));

vi.mock("@/lib/chat", () => ({
	getChatMessageByDiscussionId: mocks.getChatMessageByDiscussionId,
	pushChatMessage: mocks.pushChatMessage,
	updateChatMessageContent: mocks.updateChatMessageContent,
}));

vi.mock("@/lib/events", () => ({
	pushEvent: mocks.pushEvent,
}));

const WEBHOOK_SECRET = "route-contract-webhook-secret";

function signedWebhookRequest(
	eventType: string,
	deliveryId: string,
	payload: Record<string, unknown>,
	extraHeaders: Record<string, string> = {},
): Request {
	const body = JSON.stringify(payload);
	const signature = `sha256=${crypto
		.createHmac("sha256", WEBHOOK_SECRET)
		.update(body)
		.digest("hex")}`;
	return new Request("http://localhost/api/webhooks/github", {
		method: "POST",
		headers: {
			"content-type": "application/json",
			"x-github-delivery": deliveryId,
			"x-github-event": eventType,
			"x-hub-signature-256": signature,
			...extraHeaders,
		},
		body,
	});
}

function pullRequestPayload(): Record<string, unknown> {
	return {
		action: "opened",
		repository: {
			full_name: "fairchild/workspaces",
			html_url: "https://github.com/fairchild/workspaces",
			name: "workspaces",
		},
		// No body: updateDispatchFromWebhook bails before touching the database.
		pull_request: {
			number: 123,
			title: "Add a thing",
			html_url: "https://github.com/fairchild/workspaces/pull/123",
			head: { ref: "feature/x", sha: "abc123def456" },
			base: { ref: "main" },
			draft: false,
		},
	};
}

function discussionCommentPayload(): Record<string, unknown> {
	return {
		action: "created",
		repository: { full_name: "fairchild/workspaces" },
		discussion: {
			node_id: "D_kwDO123",
			html_url: "https://github.com/fairchild/workspaces/discussions/7",
		},
		comment: {
			id: 4242,
			body: "status: still working",
			html_url:
				"https://github.com/fairchild/workspaces/discussions/7#discussioncomment-4242",
			created_at: "2026-08-02T12:00:00Z",
			user: { login: "fairchild", type: "User" },
		},
	};
}

describe("/api/webhooks/github POST", () => {
	beforeEach(() => {
		vi.stubEnv("GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET", WEBHOOK_SECRET);
		mocks.getChatMessageByDiscussionId.mockReset();
		mocks.pushChatMessage.mockReset();
		mocks.pushChatMessage.mockResolvedValue(undefined);
		mocks.pushEvent.mockReset();
		mocks.pushEvent.mockResolvedValue(undefined);
		mocks.updateChatMessageContent.mockReset();
	});

	afterEach(() => {
		vi.unstubAllEnvs();
		vi.restoreAllMocks();
	});

	it("rejects payloads whose HMAC does not match the shared secret", async () => {
		const consoleWarn = vi.spyOn(console, "warn").mockImplementation(() => {});
		const { POST } = await import("./route");
		const response = await POST(
			signedWebhookRequest("pull_request", "bad-hmac", pullRequestPayload(), {
				"x-hub-signature-256": "sha256=bad",
			}),
		);

		expect(response.status).toBe(401);
		expect(await response.text()).toBe("invalid signature");
		expect(mocks.pushEvent).not.toHaveBeenCalled();
		consoleWarn.mockRestore();
	});

	it("ignores event types the route does not bridge", async () => {
		const { POST } = await import("./route");
		const response = await POST(
			signedWebhookRequest("star", "unsupported", {
				action: "created",
				repository: { full_name: "fairchild/workspaces" },
			}),
		);

		expect(response.status).toBe(200);
		expect(await response.text()).toBe("ignored");
		expect(mocks.pushEvent).not.toHaveBeenCalled();
	});

	it("records supported events on the event stream", async () => {
		const { POST } = await import("./route");
		const response = await POST(
			signedWebhookRequest("pull_request", "pr-delivery", pullRequestPayload()),
		);

		expect(response.status).toBe(200);
		await expect(response.json()).resolves.toEqual({ ok: true });
		expect(mocks.pushEvent).toHaveBeenCalledTimes(1);
		expect(mocks.pushEvent.mock.calls[0][0]).toMatchObject({
			id: "pr-delivery",
			type: "pull_request",
			action: "opened",
			repo: "fairchild/workspaces",
			summary: "opened #123: Add a thing",
		});
	});

	it("bridges discussion comments into chat messages", async () => {
		const { POST } = await import("./route");
		const response = await POST(
			signedWebhookRequest(
				"discussion_comment",
				"discussion-delivery",
				discussionCommentPayload(),
			),
		);

		expect(response.status).toBe(200);
		expect(mocks.pushChatMessage).toHaveBeenCalledTimes(1);
		expect(mocks.pushChatMessage.mock.calls[0][0]).toMatchObject({
			id: "ghdc-4242",
			repo: "fairchild/workspaces",
			author: "fairchild",
			authorType: "user",
			content: "status: still working",
			discussionId: "D_kwDO123",
		});
	});
});
