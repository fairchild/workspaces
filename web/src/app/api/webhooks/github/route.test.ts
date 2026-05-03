import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	getChatMessageByDiscussionId: vi.fn(),
	pushChatMessage: vi.fn(),
	pushEvent: vi.fn(),
	triggerPrReview: vi.fn(),
	updateChatMessageContent: vi.fn(),
}));

vi.mock("@/lib/agent-runtime/pr-review", () => ({
	triggerPrReview: mocks.triggerPrReview,
}));

vi.mock("@/lib/chat", () => ({
	getChatMessageByDiscussionId: mocks.getChatMessageByDiscussionId,
	pushChatMessage: mocks.pushChatMessage,
	updateChatMessageContent: mocks.updateChatMessageContent,
}));

vi.mock("@/lib/events", () => ({
	pushEvent: mocks.pushEvent,
}));

function pullRequestOpenedRequest(): Request {
	return new Request("http://localhost/api/webhooks/github", {
		method: "POST",
		headers: {
			"x-github-delivery": "delivery-1",
			"x-github-event": "pull_request",
		},
		body: JSON.stringify({
			action: "opened",
			repository: {
				full_name: "fairchild/workspaces",
				html_url: "https://github.com/fairchild/workspaces",
				name: "workspaces",
			},
			pull_request: {
				number: 123,
				title: "Fix review kickoff",
				html_url: "https://github.com/fairchild/workspaces/pull/123",
				body: "## Evidence\n- [x] Test evidence attached",
				head: { ref: "codex-fix-review-kickoff" },
				base: { ref: "main" },
			},
		}),
	});
}

describe("/api/webhooks/github POST", () => {
	beforeEach(() => {
		vi.stubEnv("GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET", "");
		mocks.getChatMessageByDiscussionId.mockReset();
		mocks.pushChatMessage.mockReset();
		mocks.pushEvent.mockReset();
		mocks.pushEvent.mockResolvedValue(undefined);
		mocks.triggerPrReview.mockReset();
		mocks.updateChatMessageContent.mockReset();
	});

	afterEach(() => {
		vi.unstubAllEnvs();
		vi.restoreAllMocks();
	});

	it("awaits PR review session kickoff before returning", async () => {
		let resolveReview: (sessionId: string) => void = () => {};
		const reviewStarted = new Promise<string>((resolve) => {
			resolveReview = resolve;
		});
		mocks.triggerPrReview.mockReturnValue(reviewStarted);

		const { POST } = await import("./route");
		let resolved = false;
		const responsePromise = POST(pullRequestOpenedRequest()).then(
			(response) => {
				resolved = true;
				return response;
			},
		);

		await new Promise((resolve) => setTimeout(resolve, 0));

		expect(mocks.triggerPrReview).toHaveBeenCalledWith({
			number: 123,
			title: "Fix review kickoff",
			htmlUrl: "https://github.com/fairchild/workspaces/pull/123",
			body: "## Evidence\n- [x] Test evidence attached",
			headRef: "codex-fix-review-kickoff",
			baseRef: "main",
			repoUrl: "https://github.com/fairchild/workspaces",
			repoFullName: "fairchild/workspaces",
			repoName: "workspaces",
		});
		expect(resolved).toBe(false);

		resolveReview("sesn_123");
		const response = await responsePromise;

		expect(response.status).toBe(200);
		expect(resolved).toBe(true);
	});

	it("logs PR review kickoff failures without failing the webhook", async () => {
		const error = new Error("session kickoff failed");
		const consoleError = vi
			.spyOn(console, "error")
			.mockImplementation(() => {});
		mocks.triggerPrReview.mockRejectedValue(error);

		const { POST } = await import("./route");
		const response = await POST(pullRequestOpenedRequest());

		expect(response.status).toBe(200);
		expect(consoleError).toHaveBeenCalledWith("[pr-review] failed:", error);
	});
});
