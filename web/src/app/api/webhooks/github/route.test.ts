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

function makePullRequestRequest(
	action: string,
	overrides: {
		pull_request?: Record<string, unknown>;
		changes?: Record<string, unknown>;
		sender?: Record<string, unknown>;
	} = {},
): Request {
	return new Request("http://localhost/api/webhooks/github", {
		method: "POST",
		headers: {
			"x-github-delivery": `delivery-${action}`,
			"x-github-event": "pull_request",
		},
		body: JSON.stringify({
			action,
			sender: overrides.sender ?? { login: "fairchild", type: "User" },
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
				head: { ref: "codex-fix-review-kickoff", sha: "abc123def456" },
				base: { ref: "main" },
				draft: false,
				...overrides.pull_request,
			},
			...(overrides.changes ? { changes: overrides.changes } : {}),
		}),
	});
}

function makeIssueCommentRequest(
	body: string,
	overrides: {
		sender?: Record<string, unknown>;
		comment_id?: number;
		issue_overrides?: Record<string, unknown>;
	} = {},
): Request {
	return new Request("http://localhost/api/webhooks/github", {
		method: "POST",
		headers: {
			"x-github-delivery": "delivery-comment",
			"x-github-event": "issue_comment",
		},
		body: JSON.stringify({
			action: "created",
			sender: overrides.sender ?? { login: "fairchild", type: "User" },
			repository: {
				full_name: "fairchild/workspaces",
				html_url: "https://github.com/fairchild/workspaces",
				name: "workspaces",
			},
			issue: {
				number: 123,
				title: "Fix review kickoff",
				html_url: "https://github.com/fairchild/workspaces/pull/123",
				pull_request: {
					html_url: "https://github.com/fairchild/workspaces/pull/123",
				},
				body: "PR description",
				...overrides.issue_overrides,
			},
			comment: {
				id: overrides.comment_id ?? 9001,
				body,
				html_url:
					"https://github.com/fairchild/workspaces/pull/123#issuecomment-9001",
				created_at: "2026-05-09T12:00:00Z",
				user: { login: "fairchild" },
			},
		}),
	});
}

function pullRequestOpenedRequest(): Request {
	return makePullRequestRequest("opened");
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

		expect(mocks.triggerPrReview).toHaveBeenCalledWith(
			{
				number: 123,
				title: "Fix review kickoff",
				htmlUrl: "https://github.com/fairchild/workspaces/pull/123",
				body: "## Evidence\n- [x] Test evidence attached",
				headRef: "codex-fix-review-kickoff",
				headSha: "abc123def456",
				baseRef: "main",
				repoUrl: "https://github.com/fairchild/workspaces",
				repoFullName: "fairchild/workspaces",
				repoName: "workspaces",
			},
			expect.objectContaining({ kind: "opened" }),
		);
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

	describe("trigger matrix", () => {
		beforeEach(() => {
			mocks.triggerPrReview.mockResolvedValue("sesn_test");
		});

		it("triggers reruns on synchronize with new head sha", async () => {
			const { POST } = await import("./route");
			await POST(
				makePullRequestRequest("synchronize", {
					pull_request: {
						head: { ref: "feature/x", sha: "newsha123456" },
					},
				}),
			);
			expect(mocks.triggerPrReview).toHaveBeenCalledTimes(1);
			const [payload, ctx] = mocks.triggerPrReview.mock.calls[0];
			expect(payload.headSha).toBe("newsha123456");
			expect(ctx).toMatchObject({
				kind: "synchronize",
				triggerSourceId: "newsha123456",
			});
		});

		it("triggers on PR body edits when changes.body is present", async () => {
			const { POST } = await import("./route");
			await POST(
				makePullRequestRequest("edited", {
					changes: { body: { from: "old description" } },
				}),
			);
			expect(mocks.triggerPrReview).toHaveBeenCalledTimes(1);
			expect(mocks.triggerPrReview.mock.calls[0][1]).toMatchObject({
				kind: "edited",
			});
		});

		it("does not trigger on PR edits without body changes", async () => {
			const { POST } = await import("./route");
			await POST(
				makePullRequestRequest("edited", {
					changes: { title: { from: "old title" } },
				}),
			);
			expect(mocks.triggerPrReview).not.toHaveBeenCalled();
		});

		it("triggers on ready_for_review even though prior was draft", async () => {
			const { POST } = await import("./route");
			await POST(makePullRequestRequest("ready_for_review"));
			expect(mocks.triggerPrReview).toHaveBeenCalledTimes(1);
			expect(mocks.triggerPrReview.mock.calls[0][1]).toMatchObject({
				kind: "ready_for_review",
			});
		});

		it("skips draft PRs on synchronize", async () => {
			const { POST } = await import("./route");
			await POST(
				makePullRequestRequest("synchronize", {
					pull_request: {
						draft: true,
						head: { ref: "feature/x", sha: "newsha123456" },
					},
				}),
			);
			expect(mocks.triggerPrReview).not.toHaveBeenCalled();
		});

		it("skips events from the reviewer bot itself", async () => {
			const { POST } = await import("./route");
			await POST(
				makePullRequestRequest("synchronize", {
					sender: {
						login: "workspaces-claude-pr-reviewer[bot]",
						type: "Bot",
					},
				}),
			);
			expect(mocks.triggerPrReview).not.toHaveBeenCalled();
		});

		it("triggers on a non-bot evidence-bearing PR comment", async () => {
			const { POST } = await import("./route");
			await POST(
				makeIssueCommentRequest(
					"Evidence: https://evidence.cloudcompute.com/pr-123-check.png",
				),
			);
			expect(mocks.triggerPrReview).toHaveBeenCalledTimes(1);
			const [, ctx] = mocks.triggerPrReview.mock.calls[0];
			expect(ctx).toMatchObject({ kind: "evidence_comment" });
			expect(ctx.triggerSourceId).toBe("comment-9001");
		});

		it("does not trigger on a bot evidence comment", async () => {
			const { POST } = await import("./route");
			await POST(
				makeIssueCommentRequest("Evidence: cloudcompute uploaded by bot", {
					sender: { login: "github-actions[bot]", type: "Bot" },
				}),
			);
			expect(mocks.triggerPrReview).not.toHaveBeenCalled();
		});

		it("does not trigger on a comment without evidence signals", async () => {
			const { POST } = await import("./route");
			await POST(makeIssueCommentRequest("looks good, ship it"));
			expect(mocks.triggerPrReview).not.toHaveBeenCalled();
		});

		it("does not trigger on issue comments outside PR threads", async () => {
			const { POST } = await import("./route");
			await POST(
				makeIssueCommentRequest("Evidence: link", {
					issue_overrides: { pull_request: undefined },
				}),
			);
			expect(mocks.triggerPrReview).not.toHaveBeenCalled();
		});
	});
});
