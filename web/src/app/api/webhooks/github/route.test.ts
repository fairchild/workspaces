import crypto from "node:crypto";
import { PR_REVIEW_WEBHOOK_CONTRACT_CASES } from "@/lib/agent-runtime/__tests__/pr-review-trigger-fixtures";
import {
	type PrReviewTriggerClassification,
	type PrReviewTriggerClassificationKind,
	classifyPrReviewTrigger,
} from "@/lib/agent-runtime/pr-review-trigger";
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

function makePullRequestPayload(
	action: string,
	overrides: {
		pull_request?: Record<string, unknown>;
		changes?: Record<string, unknown>;
		sender?: Record<string, unknown>;
	} = {},
): Record<string, unknown> {
	return {
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
	};
}

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
		body: JSON.stringify(makePullRequestPayload(action, overrides)),
	});
}

function makeIssueCommentPayload(
	body: string,
	overrides: {
		sender?: Record<string, unknown>;
		comment_id?: number;
		issue_overrides?: Record<string, unknown>;
	} = {},
): Record<string, unknown> {
	return {
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
	};
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
		body: JSON.stringify(makeIssueCommentPayload(body, overrides)),
	});
}

function makeReviewCommentPayload(): Record<string, unknown> {
	return {
		action: "created",
		sender: { login: "fairchild", type: "User" },
		repository: {
			full_name: "fairchild/workspaces",
			html_url: "https://github.com/fairchild/workspaces",
			name: "workspaces",
		},
		pull_request: {
			number: 123,
			html_url: "https://github.com/fairchild/workspaces/pull/123",
		},
		comment: {
			id: 9201,
			body: "Could this helper be smaller?",
			html_url:
				"https://github.com/fairchild/workspaces/pull/123#discussion_r9201",
		},
	};
}

function expectTrigger(
	classification: PrReviewTriggerClassification,
	kind: PrReviewTriggerClassificationKind,
) {
	expect(classification).toMatchObject({
		decision: "trigger_review",
		relevance: "material",
		kind,
	});
	if (classification.decision !== "trigger_review") {
		throw new Error(`expected ${kind} to trigger review`);
	}
	return classification.trigger;
}

function expectSkip(
	classification: PrReviewTriggerClassification,
	kind: PrReviewTriggerClassificationKind,
	relevance: "metadata" | "terminal" | "ignored",
) {
	expect(classification).toMatchObject({
		decision: "skip_review",
		kind,
		relevance,
	});
	if (classification.decision !== "skip_review") {
		throw new Error(`expected ${kind} to skip review`);
	}
}

function pullRequestOpenedRequest(): Request {
	return makePullRequestRequest("opened");
}

const CONTRACT_WEBHOOK_SECRET = "route-contract-webhook-secret";

function signedWebhookRequest(
	eventType: string,
	deliveryId: string,
	payload: Record<string, unknown>,
	extraHeaders: Record<string, string> = {},
): Request {
	const body = JSON.stringify(payload);
	const signature = `sha256=${crypto
		.createHmac("sha256", CONTRACT_WEBHOOK_SECRET)
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

describe("PR review trigger relevance classifier", () => {
	it("classifies material review triggers explicitly", () => {
		const opened = expectTrigger(
			classifyPrReviewTrigger(
				"pull_request",
				"opened",
				makePullRequestPayload("opened"),
			),
			"opened",
		);
		expect(opened.context.kind).toBe("opened");

		const synchronize = expectTrigger(
			classifyPrReviewTrigger(
				"pull_request",
				"synchronize",
				makePullRequestPayload("synchronize", {
					pull_request: { head: { ref: "feature/x", sha: "head-new" } },
				}),
			),
			"synchronize",
		);
		expect(synchronize.context).toMatchObject({
			kind: "synchronize",
			triggerSourceId: "head-new",
		});

		const bodyEdit = expectTrigger(
			classifyPrReviewTrigger(
				"pull_request",
				"edited",
				makePullRequestPayload("edited", {
					pull_request: { body: "Updated evidence and summary" },
					changes: { body: { from: "old body" } },
				}),
			),
			"body_edit",
		);
		expect(bodyEdit.context.kind).toBe("edited");
		expect(bodyEdit.context.triggerSourceId).toMatch(/^body-/);

		const baseEdit = expectTrigger(
			classifyPrReviewTrigger(
				"pull_request",
				"edited",
				makePullRequestPayload("edited", {
					pull_request: { base: { ref: "release/2026-05" } },
					changes: { base: { ref: { from: "main" } } },
				}),
			),
			"base_edit",
		);
		expect(baseEdit.context.triggerSourceId).toBe(
			"base-release/2026-05-abc123def456",
		);

		const evidenceComment = expectTrigger(
			classifyPrReviewTrigger(
				"issue_comment",
				"created",
				makeIssueCommentPayload(
					"Evidence: https://evidence.cloudcompute.com/pr-123.png",
				),
			),
			"evidence_comment",
		);
		expect(evidenceComment.context).toMatchObject({
			kind: "evidence_comment",
			triggerSourceId: "comment-9001",
		});

		const validationComment = expectTrigger(
			classifyPrReviewTrigger(
				"issue_comment",
				"created",
				makeIssueCommentPayload(
					"Validation: mise -C web run web:check passed",
					{
						comment_id: 9002,
					},
				),
			),
			"evidence_comment",
		);
		expect(validationComment.context).toMatchObject({
			kind: "evidence_comment",
			triggerSourceId: "comment-9002",
		});
	});

	it("classifies metadata and terminal events without managed-review sessions", () => {
		expectSkip(
			classifyPrReviewTrigger(
				"pull_request",
				"edited",
				makePullRequestPayload("edited", {
					changes: { title: { from: "old title" } },
				}),
			),
			"metadata_edit",
			"metadata",
		);
		expectSkip(
			classifyPrReviewTrigger(
				"issue_comment",
				"created",
				makeIssueCommentPayload("looks good, ship it"),
			),
			"non_evidence_comment",
			"metadata",
		);
		expectSkip(
			classifyPrReviewTrigger(
				"issue_comment",
				"created",
				makeIssueCommentPayload(
					"Managed review approved with no requested changes. Local and CI validation are green.",
				),
			),
			"non_evidence_comment",
			"metadata",
		);
		expectSkip(
			classifyPrReviewTrigger(
				"issue_comment",
				"created",
				makeIssueCommentPayload(
					"Review response: no changes. The Playwright cache path is working as intended.",
				),
			),
			"non_evidence_comment",
			"metadata",
		);
		expectSkip(
			classifyPrReviewTrigger(
				"pull_request_review_comment",
				"created",
				makeReviewCommentPayload(),
			),
			"review_comment",
			"metadata",
		);
		expectSkip(
			classifyPrReviewTrigger(
				"pull_request",
				"labeled",
				makePullRequestPayload("labeled"),
			),
			"label",
			"metadata",
		);
		expectSkip(
			classifyPrReviewTrigger(
				"pull_request",
				"closed",
				makePullRequestPayload("closed"),
			),
			"closed",
			"terminal",
		);
	});

	it("keeps repeated body edits and evidence comments idempotent by source id", () => {
		const firstBody = expectTrigger(
			classifyPrReviewTrigger(
				"pull_request",
				"edited",
				makePullRequestPayload("edited", {
					pull_request: { body: "body version one" },
					changes: { body: { from: "old body" } },
				}),
			),
			"body_edit",
		);
		const redeliveredBody = expectTrigger(
			classifyPrReviewTrigger(
				"pull_request",
				"edited",
				makePullRequestPayload("edited", {
					pull_request: { body: "body version one" },
					changes: { body: { from: "old body" } },
				}),
			),
			"body_edit",
		);
		const updatedBody = expectTrigger(
			classifyPrReviewTrigger(
				"pull_request",
				"edited",
				makePullRequestPayload("edited", {
					pull_request: { body: "body version two" },
					changes: { body: { from: "body version one" } },
				}),
			),
			"body_edit",
		);

		expect(redeliveredBody.context.triggerSourceId).toBe(
			firstBody.context.triggerSourceId,
		);
		expect(updatedBody.context.triggerSourceId).not.toBe(
			firstBody.context.triggerSourceId,
		);

		const firstEvidence = expectTrigger(
			classifyPrReviewTrigger(
				"issue_comment",
				"created",
				makeIssueCommentPayload("Evidence: validation attached", {
					comment_id: 9101,
				}),
			),
			"evidence_comment",
		);
		const redeliveredEvidence = expectTrigger(
			classifyPrReviewTrigger(
				"issue_comment",
				"created",
				makeIssueCommentPayload("Evidence: validation attached", {
					comment_id: 9101,
				}),
			),
			"evidence_comment",
		);
		const nextEvidence = expectTrigger(
			classifyPrReviewTrigger(
				"issue_comment",
				"created",
				makeIssueCommentPayload("Evidence: validation attached", {
					comment_id: 9102,
				}),
			),
			"evidence_comment",
		);

		expect(redeliveredEvidence.context.triggerSourceId).toBe(
			firstEvidence.context.triggerSourceId,
		);
		expect(nextEvidence.context.triggerSourceId).not.toBe(
			firstEvidence.context.triggerSourceId,
		);
	});
});

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

	it("leaves review publishing to the broker after kickoff", async () => {
		mocks.triggerPrReview.mockResolvedValue("sesn_123");

		const { POST } = await import("./route");
		const response = await POST(pullRequestOpenedRequest());

		expect(response.status).toBe(200);
		expect(mocks.triggerPrReview).toHaveBeenCalledWith(
			expect.any(Object),
			expect.objectContaining({ kind: "opened" }),
		);
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

		it("does not trigger on PR edits without body or base changes", async () => {
			const { POST } = await import("./route");
			await POST(
				makePullRequestRequest("edited", {
					changes: { title: { from: "old title" } },
				}),
			);
			expect(mocks.triggerPrReview).not.toHaveBeenCalled();
		});

		it("does not start review sessions for metadata-only PR events", async () => {
			const { POST } = await import("./route");
			await POST(makePullRequestRequest("labeled"));
			await POST(makePullRequestRequest("unlabeled"));
			await POST(makePullRequestRequest("closed"));
			await POST(
				makePullRequestRequest("edited", {
					changes: { title: { from: "old title" } },
				}),
			);
			expect(mocks.triggerPrReview).not.toHaveBeenCalled();
		});

		it("routes mixed metadata and material triggers without metadata sessions", async () => {
			const { POST } = await import("./route");
			await POST(makePullRequestRequest("labeled"));
			await POST(
				makePullRequestRequest("synchronize", {
					pull_request: {
						head: { ref: "feature/x", sha: "materialsha123" },
					},
				}),
			);
			await POST(
				makeIssueCommentRequest("Evidence: tests uploaded", {
					comment_id: 9002,
				}),
			);

			expect(mocks.triggerPrReview).toHaveBeenCalledTimes(2);
			expect(mocks.triggerPrReview.mock.calls[0][1]).toMatchObject({
				kind: "synchronize",
				triggerSourceId: "materialsha123",
			});
			expect(mocks.triggerPrReview.mock.calls[1][1]).toMatchObject({
				kind: "evidence_comment",
				triggerSourceId: "comment-9002",
			});
		});

		it("triggers when the PR base branch is retargeted", async () => {
			const { POST } = await import("./route");
			await POST(
				makePullRequestRequest("edited", {
					pull_request: {
						base: { ref: "release/2026-05" },
						head: { ref: "feature/x", sha: "abc123def456" },
					},
					changes: { base: { ref: { from: "main" } } },
				}),
			);
			expect(mocks.triggerPrReview).toHaveBeenCalledTimes(1);
			const [payload, ctx] = mocks.triggerPrReview.mock.calls[0];
			expect(payload.baseRef).toBe("release/2026-05");
			expect(ctx).toMatchObject({
				kind: "edited",
				triggerSourceId: "base-release/2026-05-abc123def456",
			});
			expect(ctx.reason).toContain("base branch");
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
			await POST(
				makeIssueCommentRequest(
					"Managed review approved with no requested changes. Local and CI validation are green.",
				),
			);
			await POST(
				makeIssueCommentRequest(
					"Review response: no changes. The Playwright cache path is working as intended.",
				),
			);
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

	describe("shared reviewer ingress contract", () => {
		beforeEach(() => {
			vi.stubEnv(
				"GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET",
				CONTRACT_WEBHOOK_SECRET,
			);
			mocks.triggerPrReview.mockResolvedValue("sesn_contract");
		});

		for (const testCase of PR_REVIEW_WEBHOOK_CONTRACT_CASES) {
			it(`${testCase.expectedTriggerKind ? "triggers" : "skips"} ${testCase.name}`, async () => {
				const { POST } = await import("./route");
				const response = await POST(
					signedWebhookRequest(
						testCase.eventType,
						testCase.deliveryId,
						testCase.payload,
					),
				);

				expect(response.status).toBe(200);
				if (testCase.expectedTriggerKind) {
					expect(mocks.triggerPrReview).toHaveBeenCalledTimes(1);
					expect(mocks.triggerPrReview.mock.calls[0][1]).toMatchObject({
						kind: testCase.expectedTriggerKind,
					});
				} else {
					expect(mocks.triggerPrReview).not.toHaveBeenCalled();
				}
			});
		}
	});

	describe("reviewer ingress canary", () => {
		beforeEach(() => {
			vi.stubEnv(
				"GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET",
				CONTRACT_WEBHOOK_SECRET,
			);
			vi.stubEnv("WORKSPACES_WEBHOOK_CANARY_SECRET", "canary-secret");
			mocks.triggerPrReview.mockResolvedValue("sesn_should_not_start");
		});

		it("returns a dry-run trigger result without writing events or starting an agent", async () => {
			const { POST } = await import("./route");
			const response = await POST(
				signedWebhookRequest(
					"pull_request",
					"canary-delivery",
					PR_REVIEW_WEBHOOK_CONTRACT_CASES[0].payload,
					{ "x-workspace-webhook-canary": "canary-secret" },
				),
			);

			expect(response.status).toBe(200);
			await expect(response.json()).resolves.toMatchObject({
				ok: true,
				canary: true,
				wouldTrigger: true,
				triggerKind: "opened",
				eventType: "pull_request",
				action: "opened",
				repo: "fairchild/workspaces",
			});
			expect(mocks.pushEvent).not.toHaveBeenCalled();
			expect(mocks.triggerPrReview).not.toHaveBeenCalled();
		});

		it("rejects canary requests with a valid HMAC but the wrong canary secret", async () => {
			const consoleWarn = vi
				.spyOn(console, "warn")
				.mockImplementation(() => {});
			const { POST } = await import("./route");
			const response = await POST(
				signedWebhookRequest(
					"pull_request",
					"canary-bad-secret",
					PR_REVIEW_WEBHOOK_CONTRACT_CASES[0].payload,
					{ "x-workspace-webhook-canary": "wrong-secret" },
				),
			);

			expect(response.status).toBe(401);
			await expect(response.json()).resolves.toMatchObject({
				ok: false,
				canary: true,
				error: "invalid_canary_secret",
			});
			expect(mocks.pushEvent).not.toHaveBeenCalled();
			expect(mocks.triggerPrReview).not.toHaveBeenCalled();
			consoleWarn.mockRestore();
		});

		it("requires a valid GitHub HMAC before honoring the canary secret", async () => {
			const consoleWarn = vi
				.spyOn(console, "warn")
				.mockImplementation(() => {});
			const { POST } = await import("./route");
			const response = await POST(
				signedWebhookRequest(
					"pull_request",
					"canary-bad-hmac",
					PR_REVIEW_WEBHOOK_CONTRACT_CASES[0].payload,
					{
						"x-hub-signature-256": "sha256=bad",
						"x-workspace-webhook-canary": "canary-secret",
					},
				),
			);

			expect(response.status).toBe(401);
			expect(await response.text()).toBe("invalid signature");
			expect(mocks.pushEvent).not.toHaveBeenCalled();
			expect(mocks.triggerPrReview).not.toHaveBeenCalled();
			consoleWarn.mockRestore();
		});
	});
});
