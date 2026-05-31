import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	createSession: vi.fn(),
	listEvents: vi.fn(),
	sendEvent: vi.fn(),
	uploadFile: vi.fn(),
	getOrCreateAgent: vi.fn(),
	getOrCreateEnvironment: vi.fn(),
	getInstallationToken: vi.fn(),
	fetch: vi.fn(),
	recordRunStart: vi.fn(),
	recordRunResult: vi.fn(),
	releaseRunActiveClaim: vi.fn(),
	listStartedPrReviewRuns: vi.fn(),
	computeRunFingerprint: vi.fn(),
	beginPrReviewProjectionAttempt: vi.fn(),
	classifyPrReviewProjectionError: vi.fn(),
	recordPrReviewProjectionFailure: vi.fn(),
	recordPrReviewProjectionSuccess: vi.fn(),
}));

vi.mock("@anthropic-ai/sdk", () => {
	class FakeAnthropic {
		beta = {
			files: {
				upload: mocks.uploadFile,
			},
			sessions: {
				create: mocks.createSession,
				events: {
					list: mocks.listEvents,
					send: mocks.sendEvent,
				},
			},
		};
	}
	return { default: FakeAnthropic };
});

vi.mock("../managed-agents-cache", () => ({
	getOrCreateAgent: mocks.getOrCreateAgent,
	getOrCreateEnvironment: mocks.getOrCreateEnvironment,
}));

vi.mock("../../github-app-auth", () => ({
	getInstallationToken: mocks.getInstallationToken,
}));

vi.mock("../pr-review-runs", () => ({
	beginPrReviewProjectionAttempt: mocks.beginPrReviewProjectionAttempt,
	classifyPrReviewProjectionError: mocks.classifyPrReviewProjectionError,
	computeRunFingerprint: mocks.computeRunFingerprint,
	listStartedPrReviewRuns: mocks.listStartedPrReviewRuns,
	recordPrReviewProjectionFailure: mocks.recordPrReviewProjectionFailure,
	recordPrReviewProjectionSuccess: mocks.recordPrReviewProjectionSuccess,
	recordRunStart: mocks.recordRunStart,
	recordRunResult: mocks.recordRunResult,
	releaseRunActiveClaim: mocks.releaseRunActiveClaim,
}));

vi.stubGlobal("fetch", mocks.fetch);

import {
	type PrReviewPayload,
	fetchPrEvidenceContext,
	fetchPrNarrativeContext,
	formatPrEvidenceContext,
	formatPrNarrativeContext,
	parseReviewIntentFromText,
	processPendingPrReviewRuns,
	triggerPrReview,
} from "../pr-review";

function payload(overrides: Partial<PrReviewPayload> = {}): PrReviewPayload {
	return {
		number: 9,
		title: "Add narrative review context",
		htmlUrl: "https://github.com/fairchild/workspaces/pull/9",
		body: `## Summary
Adds narrative review context.

## Evidence
- [x] Test evidence attached (Playwright report, test output, or equivalent)
- https://evidence.cloudcompute.com/pr-9.png`,
		headRef: "feature/pr-narrative",
		headSha: "deadbeefcafebabe1234567890abcdef12345678",
		baseRef: "main",
		repoUrl: "https://github.com/fairchild/workspaces",
		repoFullName: "fairchild/workspaces",
		repoName: "workspaces",
		...overrides,
	};
}

function githubPr(number: number, overrides: Record<string, unknown> = {}) {
	return {
		number,
		title: `PR ${number}`,
		html_url: `https://github.com/fairchild/workspaces/pull/${number}`,
		state: number % 2 === 0 ? "closed" : "open",
		updated_at: `2026-05-0${number}T12:00:00Z`,
		body: `Description for PR ${number}`,
		labels: [],
		head: { ref: `branch-${number}` },
		base: { ref: "main" },
		...overrides,
	};
}

function githubLabel(name: string, description = "") {
	return {
		name,
		description,
		color: "ededed",
	};
}

function githubIssueComment(
	body: string,
	overrides: Record<string, unknown> = {},
) {
	return {
		body,
		html_url: "https://github.com/fairchild/workspaces/pull/9#issuecomment-1",
		created_at: "2026-05-03T12:00:00Z",
		user: { login: "fairchild" },
		...overrides,
	};
}

async function* asyncEvents(events: unknown[]) {
	for (const event of events) {
		yield event;
	}
}

function isManagedReviewStatusUrl(url: string): boolean {
	return url.includes("/statuses/");
}

function okResponse() {
	return { ok: true, text: async () => "", json: async () => ({}) };
}

function mockPrList(prs: unknown[]) {
	mockNarrativeFetch({ prs });
}

function mockNarrativeFetch({
	prs,
	labels = [],
	reviewedPrs = [],
	comments = [],
	failLabels = false,
	failComments = false,
}: {
	prs: unknown[];
	labels?: unknown[];
	reviewedPrs?: number[];
	comments?: unknown[];
	failLabels?: boolean;
	failComments?: boolean;
}) {
	mocks.fetch.mockImplementation(async (url: string) => {
		if (url.includes("/pulls?")) {
			return {
				ok: true,
				json: async () => prs,
			};
		}

		if (url.includes("/labels?")) {
			if (failLabels) {
				return {
					ok: false,
					status: 502,
					json: async () => ({ message: "bad gateway" }),
				};
			}
			return {
				ok: true,
				json: async () => labels,
			};
		}

		if (url.includes("/issues/9/comments?")) {
			if (failComments) {
				return {
					ok: false,
					status: 503,
					json: async () => ({ message: "unavailable" }),
				};
			}
			return {
				ok: true,
				json: async () => comments,
			};
		}

		const reviewMatch = url.match(/\/pulls\/(\d+)\/reviews\?/);
		if (reviewMatch) {
			const prNumber = Number(reviewMatch[1]);
			return {
				ok: true,
				json: async () =>
					reviewedPrs.includes(prNumber)
						? [{ user: { login: "workspaces-claude-pr-reviewer[bot]" } }]
						: [{ user: { login: "fairchild" } }],
			};
		}

		if (isManagedReviewStatusUrl(url)) {
			return okResponse();
		}

		throw new Error(`Unexpected fetch URL: ${url}`);
	});
}

beforeEach(() => {
	vi.stubEnv("ANTHROPIC_API_KEY", "sk-test");
	vi.stubEnv("GITHUB_TOKEN", "ghp_test");
	vi.stubEnv("PR_REVIEWER_ENABLED", "1");
	vi.stubEnv("PR_REVIEWER_MODEL", "claude-test");
	vi.stubEnv("PR_REVIEWER_APP_ID", "123");
	vi.stubEnv("PR_REVIEWER_PRIVATE_KEY", "private-key");
	vi.stubEnv("PR_REVIEWER_INSTALLATION_ID", "456");
	vi.stubEnv("WORKSPACES_WEB_BASE_URL", "https://spaces.cloudcompute.com");
	mocks.createSession.mockReset();
	mocks.listEvents.mockReset();
	mocks.sendEvent.mockReset();
	mocks.uploadFile.mockReset();
	mocks.getOrCreateAgent.mockReset();
	mocks.getOrCreateEnvironment.mockReset();
	mocks.getInstallationToken.mockReset();
	mocks.fetch.mockReset();
	mocks.recordRunStart.mockReset();
	mocks.recordRunResult.mockReset();
	mocks.releaseRunActiveClaim.mockReset();
	mocks.listStartedPrReviewRuns.mockReset();
	mocks.computeRunFingerprint.mockReset();
	mocks.beginPrReviewProjectionAttempt.mockReset();
	mocks.classifyPrReviewProjectionError.mockReset();
	mocks.recordPrReviewProjectionFailure.mockReset();
	mocks.recordPrReviewProjectionSuccess.mockReset();

	mocks.getOrCreateAgent.mockResolvedValue("agent_01");
	mocks.getOrCreateEnvironment.mockResolvedValue("env_01");
	mocks.getInstallationToken.mockResolvedValue("ghs_app_token");
	mocks.uploadFile.mockResolvedValue({ id: "file_01" });
	mocks.createSession.mockResolvedValue({ id: "sesn_01" });
	mocks.sendEvent.mockResolvedValue({});
	mocks.computeRunFingerprint.mockReturnValue("fp_test");
	mocks.recordRunStart.mockResolvedValue({ inserted: true });
	mocks.recordRunResult.mockResolvedValue(undefined);
	mocks.releaseRunActiveClaim.mockResolvedValue(undefined);
	mocks.listStartedPrReviewRuns.mockResolvedValue([]);
	mocks.beginPrReviewProjectionAttempt.mockImplementation(
		async (input: { type: string }) => ({
			projectionId: `proj_${input.type}`,
			desiredPayloadHash: "hash_01",
			shouldProject: true,
			attempts: 1,
			state: "projecting",
			observedExternalId: null,
		}),
	);
	mocks.classifyPrReviewProjectionError.mockReturnValue("unknown");
	mocks.recordPrReviewProjectionFailure.mockResolvedValue(undefined);
	mocks.recordPrReviewProjectionSuccess.mockResolvedValue(undefined);
});

afterEach(() => {
	vi.unstubAllEnvs();
	vi.restoreAllMocks();
});

describe("fetchPrEvidenceContext", () => {
	it("returns recent PR comments for evidence judgement", async () => {
		mockNarrativeFetch({
			prs: [githubPr(9), githubPr(8)],
			comments: [
				githubIssueComment(
					"Evidence: https://evidence.cloudcompute.com/pr-9-check.png",
				),
			],
		});

		const context = await fetchPrEvidenceContext("ghp_test", payload());

		expect(context).toEqual({
			comments: [
				{
					author: "fairchild",
					url: "https://github.com/fairchild/workspaces/pull/9#issuecomment-1",
					createdAt: "2026-05-03T12:00:00Z",
					body: "Evidence: https://evidence.cloudcompute.com/pr-9-check.png",
				},
			],
		});
	});

	it("continues when evidence comments are unavailable", async () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
		mockNarrativeFetch({
			prs: [githubPr(9), githubPr(8)],
			failComments: true,
		});

		const context = await fetchPrEvidenceContext("ghp_test", payload());

		expect(context).toEqual({
			comments: [],
			unavailableReason: "GitHub API 503",
		});
		expect(warn).toHaveBeenCalledWith(
			"[pr-review] evidence comments unavailable:",
			"GitHub API 503",
		);
	});

	it("formats evidence context comments", () => {
		const context = formatPrEvidenceContext({
			comments: [
				{
					author: "github-actions[bot]",
					url: "https://github.com/fairchild/workspaces/pull/9#issuecomment-2",
					createdAt: "2026-05-03T12:15:00Z",
					body: "Evidence reminder — missing uploaded evidence.",
				},
			],
		});

		expect(context).toContain("github-actions[bot] at 2026-05-03T12:15:00Z");
		expect(context).toContain("Evidence reminder — missing uploaded evidence.");
	});
});

describe("fetchPrNarrativeContext", () => {
	it("excludes the current PR and caps recent descriptions and relationship candidates", async () => {
		mockPrList([
			githubPr(9),
			githubPr(8),
			githubPr(7),
			githubPr(6),
			githubPr(5),
			githubPr(4),
			githubPr(3),
		]);

		const context = await fetchPrNarrativeContext("ghp_test", payload());

		expect(context.recentDescriptions.map((pr) => pr.number)).toEqual([
			8, 7, 6,
		]);
		expect(context.relationshipCandidates.map((pr) => pr.number)).toEqual([
			8, 7, 6, 5, 4,
		]);
		expect(context.availableLabels).toEqual([]);
		expect(context.relationshipCandidates.some((pr) => pr.number === 9)).toBe(
			false,
		);
		expect(mocks.fetch).toHaveBeenCalledWith(
			"https://api.github.com/repos/fairchild/workspaces/pulls?state=all&sort=updated&direction=desc&per_page=10",
			expect.objectContaining({
				headers: expect.objectContaining({
					Authorization: "Bearer ghp_test",
				}),
			}),
		);
	});

	it("includes the full repository label inventory", async () => {
		mockNarrativeFetch({
			prs: [githubPr(9), githubPr(8)],
			labels: [
				githubLabel("documentation", "Improvements or additions to docs"),
				githubLabel("security", "Security related work"),
			],
		});

		const context = await fetchPrNarrativeContext("ghp_test", payload());

		expect(context.availableLabels).toEqual([
			{
				name: "documentation",
				description: "Improvements or additions to docs",
				color: "ededed",
			},
			{
				name: "security",
				description: "Security related work",
				color: "ededed",
			},
		]);
	});

	it("handles fewer than three previous PRs", async () => {
		mockPrList([githubPr(9), githubPr(8), githubPr(7)]);

		const context = await fetchPrNarrativeContext("ghp_test", payload());

		expect(context.recentDescriptions.map((pr) => pr.number)).toEqual([8, 7]);
		expect(context.relationshipCandidates.map((pr) => pr.number)).toEqual([
			8, 7,
		]);
		expect(context.unavailableReason).toBeUndefined();
	});

	it("includes labels from previous PRs in narrative context", async () => {
		mockPrList([
			githubPr(9),
			githubPr(8, {
				labels: [{ name: "security" }, { name: "agent-runtime" }],
			}),
		]);

		const context = await fetchPrNarrativeContext("ghp_test", payload());

		expect(context.relationshipCandidates[0].labels).toEqual([
			"security",
			"agent-runtime",
		]);
	});

	it("marks relationship candidates that have a managed reviewer review", async () => {
		mockNarrativeFetch({
			prs: [githubPr(9), githubPr(8), githubPr(7)],
			reviewedPrs: [8],
		});

		const context = await fetchPrNarrativeContext("ghp_test", payload());

		expect(context.relationshipCandidates).toMatchObject([
			{ number: 8, reviewedByManagedReviewer: true },
			{ number: 7, reviewedByManagedReviewer: false },
		]);
	});

	it("continues when the repository label inventory is unavailable", async () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
		mockNarrativeFetch({
			prs: [githubPr(9), githubPr(8)],
			failLabels: true,
		});

		const context = await fetchPrNarrativeContext("ghp_test", payload());

		expect(context.relationshipCandidates.map((pr) => pr.number)).toEqual([8]);
		expect(context.availableLabels).toEqual([]);
		expect(context.labelInventoryUnavailableReason).toBe("GitHub API 502");
		expect(warn).toHaveBeenCalledWith(
			"[pr-review] label inventory unavailable:",
			"GitHub API 502",
		);
	});

	it("formats label inventory even when no previous PRs exist", () => {
		const context = formatPrNarrativeContext({
			recentDescriptions: [],
			relationshipCandidates: [],
			availableLabels: [
				{
					name: "documentation",
					description: "Improvements or additions to docs",
					color: "ededed",
				},
			],
		});

		expect(context).toContain("No previous PRs were found");
		expect(context).toContain("Repository label inventory:");
		expect(context).toContain(
			"- documentation — Improvements or additions to docs",
		);
	});

	it("returns a non-fatal unavailable reason on GitHub API failure", async () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
		mocks.fetch.mockResolvedValue({
			ok: false,
			status: 500,
			text: async () => "server error",
		});

		const context = await fetchPrNarrativeContext("ghp_test", payload());

		expect(context).toEqual({
			recentDescriptions: [],
			relationshipCandidates: [],
			availableLabels: [],
			unavailableReason: "GitHub API 500",
		});
		expect(warn).toHaveBeenCalledWith(
			"[pr-review] previous PR context unavailable:",
			"GitHub API 500",
		);
	});
});

describe("parseReviewIntentFromText", () => {
	it("extracts and validates the final fenced JSON review intent", () => {
		const intent = parseReviewIntentFromText(
			`Finished.

\`\`\`json
{
  "event": "REQUEST_CHANGES",
  "body": "🛑 **Request changes** — Evidence is missing.\\n\\n## Summary\\nNeeds evidence.",
  "labels": ["security", "missing-label", "security"]
}
\`\`\``,
			["security"],
		);

		expect(intent).toEqual({
			event: "REQUEST_CHANGES",
			body: "🛑 **Request changes** — Evidence is missing.\n\n## Summary\nNeeds evidence.",
			labels: ["security"],
		});
	});

	it("extracts fenced JSON when the review body contains markdown code fences", () => {
		const reviewIntent = {
			event: "REQUEST_CHANGES",
			body: [
				"🛑 **Request changes** — Branch is superseded.",
				"",
				"## Summary",
				"The current branch is dirty against main.",
				"",
				"```swift",
				"let path = try #require(ClaudeIntegrationLifecycle.extractTitleEmitScript())",
				"```",
			].join("\n"),
			labels: ["bug"],
		};

		const intent = parseReviewIntentFromText(
			`I now have a complete picture.

\`\`\`json
${JSON.stringify(reviewIntent, null, 2)}
\`\`\``,
			["bug"],
		);

		expect(intent).toEqual(reviewIntent);
	});

	it("rejects unsupported review events", () => {
		expect(() =>
			parseReviewIntentFromText(
				'```json\n{"event":"MERGE","body":"ship it","labels":[]}\n```',
			),
		).toThrow(/unsupported review event/);
	});
});

describe("processPendingPrReviewRuns", () => {
	it("posts completed review intents from started managed-agent sessions", async () => {
		mocks.listStartedPrReviewRuns.mockResolvedValue([
			{
				fingerprint: "fp_486",
				repoFullName: "fairchild/workspaces",
				prNumber: 486,
				headSha: "head-sha",
				triggerKind: "opened",
				triggerSourceId: "head-sha",
				sessionId: "sesn_486",
				createdAt: "2026-05-17T06:24:27Z",
				updatedAt: "2026-05-17T06:24:27Z",
			},
		]);
		mocks.listEvents.mockReturnValue(
			asyncEvents([
				{
					type: "agent.message",
					content: [
						{
							type: "text",
							text: `Review complete.

\`\`\`json
{
  "event": "COMMENT",
  "body": "💬 **Comment** — No blocking issues found.\\n\\n## Evidence\\nSwift unavailable in managed environment.",
  "labels": ["refactor"]
}
\`\`\``,
						},
					],
				},
				{
					type: "session.status_idle",
					stop_reason: { type: "end_turn" },
				},
			]),
		);
		mocks.fetch.mockImplementation(
			async (url: string, options?: RequestInit) => {
				if (url.endsWith("/pulls/486")) {
					return {
						ok: true,
						json: async () =>
							githubPr(486, {
								title: "Refactor main window orchestration",
								html_url: "https://github.com/fairchild/workspaces/pull/486",
								body: "PR body",
								head: { ref: "codex/main-window", sha: "head-sha" },
								base: { ref: "main" },
							}),
					};
				}
				if (url.includes("/pulls?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.includes("/labels?")) {
					return { ok: true, json: async () => [githubLabel("refactor")] };
				}
				if (url.includes("/pulls/") && url.includes("/reviews?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.endsWith("/pulls/486/reviews")) {
					expect(options?.method).toBe("POST");
					expect(JSON.parse(String(options?.body))).toMatchObject({
						event: "COMMENT",
						body: expect.stringContaining("No blocking issues found"),
					});
					return {
						ok: true,
						text: async () => "",
						json: async () => ({ id: 4304929701 }),
					};
				}
				if (url.endsWith("/issues/486/labels")) {
					expect(options?.method).toBe("POST");
					expect(JSON.parse(String(options?.body))).toEqual({
						labels: ["refactor"],
					});
					return { ok: true, text: async () => "", json: async () => ({}) };
				}
				if (isManagedReviewStatusUrl(url)) {
					return okResponse();
				}
				throw new Error(`Unexpected fetch URL: ${url}`);
			},
		);

		const result = await processPendingPrReviewRuns({ limit: 1 });

		expect(result).toMatchObject({
			checked: 1,
			completed: 1,
			failed: 0,
			skippedRunning: 0,
		});
		expect(mocks.recordRunResult).toHaveBeenCalledWith("fp_486", {
			sessionId: "sesn_486",
			status: "completed",
			githubReviewId: "4304929701",
		});
		expect(mocks.beginPrReviewProjectionAttempt).toHaveBeenCalledWith(
			expect.objectContaining({
				runFingerprint: "fp_486",
				type: "github_review",
				projectionKey: "final-review",
				desiredPayload: expect.objectContaining({
					repoFullName: "fairchild/workspaces",
					prNumber: 486,
					event: "COMMENT",
					labels: ["refactor"],
				}),
			}),
		);
		expect(mocks.recordPrReviewProjectionSuccess).toHaveBeenCalledWith(
			"proj_github_review",
			{ observedExternalId: "4304929701" },
		);
		const statusPost = mocks.fetch.mock.calls.find(([url]) =>
			String(url).includes("/statuses/head-sha"),
		);
		expect(statusPost?.[1]).toMatchObject({ method: "POST" });
		expect(JSON.parse(String(statusPost?.[1]?.body))).toMatchObject({
			state: "success",
			context: "WorkSpaces Managed Review",
			description: "Managed review posted.",
			target_url:
				"https://spaces.cloudcompute.com/dashboard/review-runs/fp_486",
		});
		expect(mocks.recordPrReviewProjectionSuccess).toHaveBeenCalledWith(
			"proj_github_status",
			{ observedExternalId: null },
		);
	});

	it("skips duplicate GitHub review posts when the desired projection is already projected", async () => {
		mocks.listStartedPrReviewRuns.mockResolvedValue([
			{
				fingerprint: "fp_duplicate_projection",
				repoFullName: "fairchild/workspaces",
				prNumber: 487,
				headSha: "head-sha",
				triggerKind: "opened",
				triggerSourceId: "head-sha",
				sessionId: "sesn_duplicate_projection",
				createdAt: "2026-05-17T06:24:27Z",
				updatedAt: "2026-05-17T06:24:27Z",
			},
		]);
		mocks.beginPrReviewProjectionAttempt.mockImplementation(
			async (input: { type: string }) => ({
				projectionId: `proj_${input.type}`,
				desiredPayloadHash: "hash_01",
				shouldProject: input.type !== "github_review",
				attempts: 1,
				state: input.type === "github_review" ? "projected" : "projecting",
				observedExternalId:
					input.type === "github_review" ? "4304929777" : null,
			}),
		);
		mocks.listEvents.mockReturnValue(
			asyncEvents([
				{
					type: "agent.message",
					content: [
						{
							type: "text",
							text: `Review complete.

\`\`\`json
{"event":"COMMENT","body":"No duplicate review please.","labels":[]}
\`\`\``,
						},
					],
				},
				{
					type: "session.status_idle",
					stop_reason: { type: "end_turn" },
				},
			]),
		);
		mocks.fetch.mockImplementation(
			async (url: string, options?: RequestInit) => {
				if (url.endsWith("/pulls/487")) {
					return {
						ok: true,
						json: async () =>
							githubPr(487, {
								html_url: "https://github.com/fairchild/workspaces/pull/487",
								head: { ref: "codex/no-duplicate", sha: "head-sha" },
								base: { ref: "main" },
							}),
					};
				}
				if (url.includes("/pulls/487/reviews?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.includes("/pulls?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.includes("/labels?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.endsWith("/pulls/487/reviews") && options?.method === "POST") {
					throw new Error("duplicate review post");
				}
				if (isManagedReviewStatusUrl(url)) {
					return okResponse();
				}
				throw new Error(`Unexpected fetch URL: ${url}`);
			},
		);

		const result = await processPendingPrReviewRuns({ limit: 1 });

		expect(result).toMatchObject({
			checked: 1,
			completed: 1,
			failed: 0,
		});
		expect(mocks.recordRunResult).toHaveBeenCalledWith(
			"fp_duplicate_projection",
			{
				sessionId: "sesn_duplicate_projection",
				status: "completed",
				githubReviewId: "4304929777",
			},
		);
		expect(
			mocks.fetch.mock.calls.some(
				([url, options]) =>
					String(url).endsWith("/pulls/487/reviews") &&
					options?.method === "POST",
			),
		).toBe(false);
	});

	it("posts an operator-visible failure comment when a completed intent cannot be published", async () => {
		mocks.listStartedPrReviewRuns.mockResolvedValue([
			{
				fingerprint: "fp_bad_intent",
				repoFullName: "fairchild/workspaces",
				prNumber: 486,
				headSha: "head-sha",
				triggerKind: "opened",
				triggerSourceId: "head-sha",
				sessionId: "sesn_bad_intent",
				createdAt: "2026-05-17T06:24:27Z",
				updatedAt: "2026-05-17T06:24:27Z",
			},
		]);
		mocks.listEvents.mockReturnValue(
			asyncEvents([
				{
					type: "agent.message",
					content: [
						{
							type: "text",
							text: `Review complete.

\`\`\`json
{"event":"MERGE","body":"ship it","labels":[]}
\`\`\``,
						},
					],
				},
				{
					type: "session.status_idle",
					stop_reason: { type: "end_turn" },
				},
			]),
		);
		mocks.fetch.mockImplementation(
			async (url: string, options?: RequestInit) => {
				if (url.endsWith("/pulls/486")) {
					return {
						ok: true,
						json: async () =>
							githubPr(486, {
								title: "Refactor main window orchestration",
								html_url: "https://github.com/fairchild/workspaces/pull/486",
								body: "PR body",
								head: { ref: "codex/main-window", sha: "head-sha" },
								base: { ref: "main" },
							}),
					};
				}
				if (url.includes("/pulls/486/reviews?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.includes("/pulls?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.includes("/labels?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.endsWith("/issues/486/comments")) {
					expect(options?.method).toBe("POST");
					const body = JSON.parse(String(options?.body)).body;
					expect(body).toContain("Managed review publication failed");
					expect(body).toContain("unsupported review event");
					expect(body).toContain("MERGE");
					return okResponse();
				}
				if (isManagedReviewStatusUrl(url)) {
					expect(JSON.parse(String(options?.body))).toMatchObject({
						state: "failure",
						context: "WorkSpaces Managed Review",
						description: "Managed review failed before posting.",
					});
					return okResponse();
				}
				throw new Error(`Unexpected fetch URL: ${url}`);
			},
		);

		const result = await processPendingPrReviewRuns({ limit: 1 });

		expect(result).toMatchObject({
			checked: 1,
			completed: 0,
			failed: 1,
			skippedRunning: 0,
		});
		expect(mocks.recordRunResult).toHaveBeenCalledWith("fp_bad_intent", {
			sessionId: "sesn_bad_intent",
			status: "failed",
			error: expect.stringContaining("unsupported review event"),
		});
	});

	it("leaves still-running sessions in started state", async () => {
		mocks.listStartedPrReviewRuns.mockResolvedValue([
			{
				fingerprint: "fp_running",
				repoFullName: "fairchild/workspaces",
				prNumber: 486,
				headSha: "head-sha",
				triggerKind: "opened",
				triggerSourceId: "head-sha",
				sessionId: "sesn_running",
				createdAt: "2026-05-17T06:24:27Z",
				updatedAt: "2026-05-17T06:24:27Z",
			},
		]);
		mocks.listEvents.mockReturnValue(
			asyncEvents([
				{
					type: "agent.message",
					content: [{ type: "text", text: "still working" }],
				},
			]),
		);

		const result = await processPendingPrReviewRuns({ limit: 1 });

		expect(result).toMatchObject({
			checked: 1,
			completed: 0,
			failed: 0,
			skippedRunning: 1,
		});
		expect(mocks.recordRunResult).not.toHaveBeenCalled();
	});

	it("suppresses stale completed output when a newer trigger was coalesced", async () => {
		mocks.listStartedPrReviewRuns.mockResolvedValue([
			{
				fingerprint: "fp_coalesced_old",
				repoFullName: "fairchild/workspaces",
				prNumber: 486,
				headSha: "old-head",
				triggerKind: "synchronize",
				triggerSourceId: "old-head",
				sessionId: "sesn_old",
				createdAt: "2026-05-17T06:24:27Z",
				updatedAt: "2026-05-17T06:24:27Z",
				coalescedHeadSha: "new-head",
				coalescedTriggerKind: "edited",
				coalescedTriggerSourceId: "body-new",
				coalescedAt: "2026-05-17T06:25:00Z",
			},
		]);
		mocks.listEvents.mockReturnValue(
			asyncEvents([
				{
					type: "agent.message",
					content: [
						{
							type: "text",
							text: `Stale review output.

\`\`\`json
{"event":"APPROVE","body":"Old output should not post","labels":[]}
\`\`\``,
						},
					],
				},
				{
					type: "session.status_idle",
					stop_reason: { type: "end_turn" },
				},
			]),
		);
		mocks.fetch.mockImplementation(
			async (url: string, options?: RequestInit) => {
				if (url.endsWith("/pulls/486")) {
					return {
						ok: true,
						json: async () =>
							githubPr(486, {
								title: "Refactor main window orchestration",
								html_url: "https://github.com/fairchild/workspaces/pull/486",
								body: "Updated PR body",
								head: { ref: "codex/main-window", sha: "new-head" },
								base: { ref: "main" },
							}),
					};
				}
				if (url.includes("/pulls?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.includes("/labels?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.includes("/issues/486/comments?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.includes("/pulls/486/reviews?")) {
					return { ok: true, json: async () => [] };
				}
				if (url.endsWith("/pulls/486/reviews")) {
					throw new Error("stale review output should not be posted");
				}
				if (isManagedReviewStatusUrl(url)) {
					expect(options?.method).toBe("POST");
					return okResponse();
				}
				throw new Error(`Unexpected fetch URL: ${url}`);
			},
		);

		const result = await processPendingPrReviewRuns({ limit: 1 });

		expect(result).toMatchObject({
			checked: 1,
			completed: 0,
			superseded: 1,
			requeued: 1,
		});
		expect(mocks.createSession).toHaveBeenCalledTimes(1);
		expect(mocks.releaseRunActiveClaim).toHaveBeenCalledWith(
			"fp_coalesced_old",
		);
		expect(mocks.recordRunResult).toHaveBeenLastCalledWith(
			"fp_coalesced_old",
			expect.objectContaining({
				sessionId: "sesn_old",
				status: "superseded",
				projectionStatus: "superseded",
				error: expect.stringContaining("Follow-up session sesn_01 started"),
			}),
		);
		expect(mocks.recordRunStart).toHaveBeenCalledWith(
			expect.objectContaining({
				triggerKind: "superseded_retry",
				triggerSourceId: "coalesced-2026-05-17T06:25:00Z-head-new-head",
			}),
		);
		expect(
			mocks.fetch.mock.calls.some(
				([url, options]) =>
					String(url).endsWith("/pulls/486/reviews") &&
					options?.method === "POST",
			),
		).toBe(false);
	});

	it("supersedes a completed session when a newer managed review already covers the same head", async () => {
		mocks.listStartedPrReviewRuns.mockResolvedValue([
			{
				fingerprint: "fp_stale",
				repoFullName: "fairchild/workspaces",
				prNumber: 489,
				headSha: "same-head",
				triggerKind: "edited",
				triggerSourceId: "body-123",
				sessionId: "sesn_stale",
				createdAt: "2026-05-17T06:39:00Z",
				updatedAt: "2026-05-17T06:39:10Z",
			},
		]);
		mocks.listEvents.mockReturnValue(
			asyncEvents([
				{
					type: "agent.message",
					content: [{ type: "text", text: "stale review intent" }],
				},
				{
					type: "session.status_idle",
					stop_reason: { type: "end_turn" },
				},
			]),
		);
		mocks.fetch.mockImplementation(async (url: string) => {
			if (url.endsWith("/pulls/489")) {
				return {
					ok: true,
					json: async () =>
						githubPr(489, {
							title: "Broker managed reviewer completions",
							html_url: "https://github.com/fairchild/workspaces/pull/489",
							body: "PR body",
							head: { ref: "codex/reviewer", sha: "same-head" },
							base: { ref: "main" },
						}),
				};
			}
			if (url.includes("/pulls/489/reviews?")) {
				return {
					ok: true,
					json: async () => [
						{
							id: 4304929065,
							state: "APPROVED",
							body: "First managed review.",
							submitted_at: "2026-05-17T06:42:30Z",
							commit_id: "same-head",
							user: { login: "workspaces-claude-pr-reviewer[bot]" },
						},
					],
				};
			}
			if (isManagedReviewStatusUrl(url)) {
				return okResponse();
			}
			throw new Error(`Unexpected fetch URL: ${url}`);
		});

		const result = await processPendingPrReviewRuns({ limit: 1 });

		expect(result).toMatchObject({
			checked: 1,
			completed: 0,
			failed: 0,
			skippedRunning: 0,
			superseded: 1,
			requeued: 0,
			runs: [
				{
					fingerprint: "fp_stale",
					status: "superseded",
					supersededByReviewId: 4304929065,
					retrySessionId: null,
				},
			],
		});
		expect(mocks.createSession).not.toHaveBeenCalled();
		expect(mocks.recordRunResult).toHaveBeenCalledWith("fp_stale", {
			sessionId: "sesn_stale",
			status: "superseded",
			error: expect.stringContaining("same head"),
			projectionStatus: "projected",
			githubReviewId: "4304929065",
		});
		const statusPost = mocks.fetch.mock.calls.find(([url]) =>
			String(url).includes("/statuses/same-head"),
		);
		expect(JSON.parse(String(statusPost?.[1]?.body))).toMatchObject({
			state: "success",
			description: "Managed review posted.",
		});
	});

	it("does not requeue when any newer managed review covers the current head", async () => {
		mocks.listStartedPrReviewRuns.mockResolvedValue([
			{
				fingerprint: "fp_mixed_reviews",
				repoFullName: "fairchild/workspaces",
				prNumber: 489,
				headSha: "current-head",
				triggerKind: "synchronize",
				triggerSourceId: "current-head",
				sessionId: "sesn_mixed_reviews",
				createdAt: "2026-05-17T06:39:00Z",
				updatedAt: "2026-05-17T06:39:10Z",
			},
		]);
		mocks.listEvents.mockReturnValue(
			asyncEvents([
				{
					type: "agent.message",
					content: [{ type: "text", text: "stale review intent" }],
				},
				{
					type: "session.status_idle",
					stop_reason: { type: "end_turn" },
				},
			]),
		);
		mocks.fetch.mockImplementation(async (url: string) => {
			if (url.endsWith("/pulls/489")) {
				return {
					ok: true,
					json: async () =>
						githubPr(489, {
							title: "Broker managed reviewer completions",
							html_url: "https://github.com/fairchild/workspaces/pull/489",
							body: "PR body",
							head: { ref: "codex/reviewer", sha: "current-head" },
							base: { ref: "main" },
						}),
				};
			}
			if (url.includes("/pulls/489/reviews?")) {
				return {
					ok: true,
					json: async () => [
						{
							id: 4304929509,
							state: "APPROVED",
							body: "Later review on an older head.",
							submitted_at: "2026-05-17T06:43:04Z",
							commit_id: "old-head",
							user: { login: "workspaces-claude-pr-reviewer[bot]" },
						},
						{
							id: 4304929065,
							state: "APPROVED",
							body: "Earlier review on the current head.",
							submitted_at: "2026-05-17T06:42:30Z",
							commit_id: "current-head",
							user: { login: "workspaces-claude-pr-reviewer[bot]" },
						},
					],
				};
			}
			if (isManagedReviewStatusUrl(url)) {
				return okResponse();
			}
			throw new Error(`Unexpected fetch URL: ${url}`);
		});

		const result = await processPendingPrReviewRuns({ limit: 1 });

		expect(result).toMatchObject({
			checked: 1,
			completed: 0,
			failed: 0,
			superseded: 1,
			requeued: 0,
			runs: [
				{
					fingerprint: "fp_mixed_reviews",
					status: "superseded",
					supersededByReviewId: 4304929065,
					retrySessionId: null,
				},
			],
		});
		expect(mocks.createSession).not.toHaveBeenCalled();
		expect(mocks.recordRunResult).toHaveBeenCalledWith("fp_mixed_reviews", {
			sessionId: "sesn_mixed_reviews",
			status: "superseded",
			error: expect.stringContaining("4304929065"),
			projectionStatus: "projected",
			githubReviewId: "4304929065",
		});
	});

	it("requeues a stale completed session when the newer managed review is for an older head", async () => {
		mocks.listStartedPrReviewRuns.mockResolvedValue([
			{
				fingerprint: "fp_new_head_stale",
				repoFullName: "fairchild/workspaces",
				prNumber: 489,
				headSha: "new-head",
				triggerKind: "synchronize",
				triggerSourceId: "new-head",
				sessionId: "sesn_new_head_stale",
				createdAt: "2026-05-17T06:39:00Z",
				updatedAt: "2026-05-17T06:39:10Z",
			},
		]);
		mocks.listEvents.mockReturnValue(
			asyncEvents([
				{
					type: "agent.message",
					content: [{ type: "text", text: "stale review intent" }],
				},
				{
					type: "session.status_idle",
					stop_reason: { type: "end_turn" },
				},
			]),
		);
		mocks.fetch.mockImplementation(async (url: string) => {
			if (url.endsWith("/pulls/489")) {
				return {
					ok: true,
					json: async () =>
						githubPr(489, {
							title: "Broker managed reviewer completions",
							html_url: "https://github.com/fairchild/workspaces/pull/489",
							body: "PR body",
							head: { ref: "codex/reviewer", sha: "new-head" },
							base: { ref: "main" },
						}),
				};
			}
			if (url.includes("/pulls/489/reviews?")) {
				return {
					ok: true,
					json: async () => [
						{
							id: 4304929065,
							state: "APPROVED",
							body: "First managed review on old head.",
							submitted_at: "2026-05-17T06:42:30Z",
							commit_id: "old-head",
							user: { login: "workspaces-claude-pr-reviewer[bot]" },
						},
					],
				};
			}
			if (url.includes("/pulls?")) {
				return { ok: true, json: async () => [] };
			}
			if (url.includes("/labels?")) {
				return { ok: true, json: async () => [] };
			}
			if (url.includes("/issues/489/comments?")) {
				return { ok: true, json: async () => [] };
			}
			if (isManagedReviewStatusUrl(url)) {
				return okResponse();
			}
			throw new Error(`Unexpected fetch URL: ${url}`);
		});

		const result = await processPendingPrReviewRuns({ limit: 1 });

		expect(result).toMatchObject({
			checked: 1,
			completed: 0,
			failed: 0,
			superseded: 1,
			requeued: 1,
			runs: [
				{
					fingerprint: "fp_new_head_stale",
					status: "superseded",
					supersededByReviewId: 4304929065,
					retrySessionId: "sesn_01",
				},
			],
		});
		expect(mocks.recordRunStart).toHaveBeenCalledWith(
			expect.objectContaining({
				prNumber: 489,
				headSha: "new-head",
				triggerKind: "superseded_retry",
				triggerSourceId: "review-4304929065-head-new-head",
			}),
		);
		expect(mocks.recordRunResult).toHaveBeenCalledWith("fp_test", {
			sessionId: "sesn_01",
			status: "started",
		});
		expect(mocks.recordRunResult).toHaveBeenCalledWith("fp_new_head_stale", {
			sessionId: "sesn_new_head_stale",
			status: "superseded",
			error: expect.stringContaining("retry session sesn_01 started"),
			projectionStatus: "superseded",
			githubReviewId: "4304929065",
		});
		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(message).toContain("You reviewed this PR before");
		expect(message).toContain("First managed review on old head.");
	});
});

describe("triggerPrReview", () => {
	it("does not fall back to GITHUB_TOKEN when the reviewer is explicitly disabled", async () => {
		vi.stubEnv("PR_REVIEWER_ENABLED", "0");
		mockPrList([githubPr(9), githubPr(8)]);

		await expect(triggerPrReview(payload())).resolves.toBeNull();

		expect(mocks.getInstallationToken).not.toHaveBeenCalled();
		expect(mocks.createSession).not.toHaveBeenCalled();
	});

	it("starts when GitHub App credentials are configured without a separate enable flag", async () => {
		vi.stubEnv("PR_REVIEWER_ENABLED", "");
		mockPrList([githubPr(9), githubPr(8)]);

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		expect(mocks.getInstallationToken).toHaveBeenCalledWith(
			"123",
			"private-key",
			"456",
		);
		expect(mocks.createSession).toHaveBeenCalledTimes(1);
	});

	it("posts a pending PR status after the managed reviewer is kicked off", async () => {
		mockPrList([githubPr(9), githubPr(8)]);

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		const statusCallIndex = mocks.fetch.mock.calls.findIndex(([url]) =>
			String(url).includes(
				"/statuses/deadbeefcafebabe1234567890abcdef12345678",
			),
		);
		expect(statusCallIndex).toBeGreaterThanOrEqual(0);
		const [, statusOptions] = mocks.fetch.mock.calls[statusCallIndex];
		expect(statusOptions).toMatchObject({ method: "POST" });
		expect(JSON.parse(String(statusOptions?.body))).toMatchObject({
			state: "pending",
			context: "WorkSpaces Managed Review",
			description: "Managed reviewer picked up this PR.",
			target_url:
				"https://spaces.cloudcompute.com/dashboard/review-runs/fp_test",
		});
		const statusOrder = mocks.fetch.mock.invocationCallOrder[statusCallIndex];
		expect(statusOrder).toBeGreaterThan(
			mocks.recordRunStart.mock.invocationCallOrder[0],
		);
		expect(statusOrder).toBeLessThan(
			mocks.createSession.mock.invocationCallOrder[0],
		);
	});

	it("does not fall back to GITHUB_TOKEN when GitHub App token exchange fails", async () => {
		const error = new Error("app auth failed");
		const consoleError = vi
			.spyOn(console, "error")
			.mockImplementation(() => {});
		mocks.getInstallationToken.mockRejectedValue(error);
		mockPrList([githubPr(9), githubPr(8)]);

		await expect(triggerPrReview(payload())).resolves.toBeNull();

		expect(mocks.getInstallationToken).toHaveBeenCalledWith(
			"123",
			"private-key",
			"456",
		);
		expect(consoleError).toHaveBeenCalledWith(
			"[pr-review] GitHub App token failed:",
			error,
		);
		expect(mocks.createSession).not.toHaveBeenCalled();
	});

	it("configures the review prompt to render details collapsed by default", async () => {
		mockPrList([githubPr(9), githubPr(8)]);

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		expect(mocks.getOrCreateAgent).toHaveBeenCalledTimes(1);
		const [, config] = mocks.getOrCreateAgent.mock.calls[0];
		const prompt = config.systemPrompt;
		expect(prompt).toContain("Produce one structured review intent");
		expect(prompt).toContain("do not use GitHub write APIs yourself");
		expect(prompt).toContain(
			"<details><summary>Details</summary> ... </details>",
		);
		expect(prompt).toContain("Do not add the `open` attribute");
		expect(prompt).toContain("Text inside `<untrusted-content>`");
		expect(prompt).not.toContain(
			"Use real headings (`## Summary`, `## Details`)",
		);
	});

	it("sends previous PR context and narrative instructions in the kickoff message", async () => {
		mockNarrativeFetch({
			prs: [githubPr(9), githubPr(8), githubPr(7), githubPr(6)],
			labels: [githubLabel("documentation", "Documentation changes")],
			reviewedPrs: [8],
		});

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		expect(mocks.createSession).toHaveBeenCalledTimes(1);
		expect(mocks.sendEvent).toHaveBeenCalledTimes(1);
		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(mocks.getInstallationToken).toHaveBeenCalledWith(
			"123",
			"private-key",
			"456",
		);
		expect(message).toContain("Previous PR narrative context:");
		expect(message).toContain("<trusted-envelope>");
		expect(message).toContain(
			'<untrusted-content name="previous-pr-narrative-context">',
		);
		expect(message).toContain("Most recently updated PR descriptions");
		expect(message).toContain("PR #8: PR 8");
		expect(message).toContain("Labels: (none)");
		expect(message).toContain("Prior managed review: yes");
		expect(message).toContain("Repository label inventory:");
		expect(message).toContain("- documentation — Documentation changes");
		expect(message).toContain("## Project Thread");
		expect(message).toContain("Reference at least one previous PR by number");
	});

	it("sends current PR evidence context and evidence judgement instructions in the kickoff message", async () => {
		mockNarrativeFetch({
			prs: [githubPr(9), githubPr(8)],
			comments: [
				githubIssueComment(
					"Evidence: https://evidence.cloudcompute.com/pr-9-check.png",
				),
			],
		});

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		const [, agentConfig] = mocks.getOrCreateAgent.mock.calls[0];
		const prompt = agentConfig.systemPrompt;
		expect(prompt).toContain("## Evidence");
		expect(prompt).toContain("set `event` to `REQUEST_CHANGES`");
		expect(prompt).toContain("concrete example of evidence");

		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(message).toContain("Current PR description:");
		expect(message).toContain(
			'<untrusted-content name="current-pr-description">',
		);
		expect(message).toContain('<untrusted-content name="recent-pr-comments">');
		expect(message).toContain("Adds narrative review context.");
		expect(message).toContain("Recent PR comments for evidence context:");
		expect(message).toContain(
			"Evidence: https://evidence.cloudcompute.com/pr-9-check.png",
		);
		expect(message).toContain(
			'Your review must include a short "## Evidence" section',
		);
		expect(message).toContain("Confirm sufficient provided evidence");
		expect(message).toContain(
			"If no evidence is provided, say whether that is acceptable",
		);
		expect(message).toContain("event to REQUEST_CHANGES");
		expect(message).toContain("concrete example of acceptable evidence");
		expect(message).toContain("bot reminders as prompts to inspect evidence");
	});

	it("keeps the PR template evidence section visible when the body is long", async () => {
		mockNarrativeFetch({
			prs: [githubPr(9), githubPr(8)],
		});

		await expect(
			triggerPrReview(
				payload({
					body: `${"Long summary line.\n".repeat(90)}
## Evidence
- [x] Test evidence attached (Playwright report, test output, or equivalent)
- https://evidence.cloudcompute.com/pr-9-check.png`,
				}),
			),
		).resolves.toBe("sesn_01");

		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(message).toContain("## Evidence");
		expect(message).toContain(
			"https://evidence.cloudcompute.com/pr-9-check.png",
		);
	});

	it("instructs the reviewer to apply high-confidence related labels and suggest label opportunities", async () => {
		mockNarrativeFetch({
			prs: [githubPr(9), githubPr(8, { labels: [{ name: "security" }] })],
			labels: [
				githubLabel("documentation", "Improvements or additions to docs"),
				githubLabel("security", "Security related work"),
			],
			reviewedPrs: [8],
		});

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(message).toContain("Labels: security");
		expect(message).toContain("include it in the `labels` array");
		expect(message).toContain(
			"do not look for environment variables or files containing GitHub credentials",
		);
		expect(message).not.toContain("POST https://api.github.com");
		expect(message).not.toContain("/workspace/.github-token");
		expect(message).toContain(
			"Labels on previous PRs that were already reviewed by workspaces-claude-pr-reviewer[bot] are stronger evidence",
		);
		expect(message).toContain(
			"Existing labels may be suggested even when they were not present on the selected related PR",
		);
		expect(message).toContain("Inherited label proposed:");
		expect(message).toContain("Existing label proposed:");
		expect(message).toContain("Label suggestion:");
		expect(message).toContain("Do not create labels");
	});

	it("uses only the repository resource token for managed-agent GitHub access", async () => {
		mockPrList([githubPr(9), githubPr(8)]);

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		expect(mocks.uploadFile).not.toHaveBeenCalled();
		const sessionRequest = mocks.createSession.mock.calls[0][0];
		expect(JSON.stringify(sessionRequest.resources)).not.toContain(
			"github-token",
		);
		expect(sessionRequest.resources[0]).toMatchObject({
			type: "github_repository",
			authorization_token: "ghs_app_token",
			checkout: { type: "branch", name: "feature/pr-narrative" },
		});
		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(message).not.toContain("ghs_app_token");
		expect(message).toContain(
			"server-side broker is the only component that may post the review or labels",
		);
		const [, envConfig] = mocks.getOrCreateEnvironment.mock.calls[0];
		expect(envConfig.config.networking.type).toBe("limited");
	});

	it("still starts the reviewer when previous PR context is unavailable", async () => {
		vi.spyOn(console, "warn").mockImplementation(() => {});
		mocks.fetch.mockResolvedValue({
			ok: false,
			status: 403,
			text: async () => "forbidden",
		});

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		expect(mocks.createSession).toHaveBeenCalledTimes(1);
		expect(mocks.sendEvent).toHaveBeenCalledTimes(1);
		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(message).toContain(
			"Previous PR context unavailable: GitHub API 403",
		);
		expect(message).toContain(
			"If no previous PR exists or the previous PR context is unavailable",
		);
	});
});

describe("triggerPrReview rerun behavior", () => {
	it("skips when recordRunStart reports a duplicate fingerprint", async () => {
		mockPrList([githubPr(9), githubPr(8)]);
		mocks.recordRunStart.mockResolvedValueOnce({ inserted: false });

		await expect(triggerPrReview(payload())).resolves.toBeNull();

		expect(mocks.createSession).not.toHaveBeenCalled();
		expect(mocks.sendEvent).not.toHaveBeenCalled();
	});

	it("updates the PR status when a trigger coalesces into an active run", async () => {
		mockPrList([githubPr(9), githubPr(8)]);
		mocks.recordRunStart.mockResolvedValueOnce({
			inserted: false,
			priorStatus: "started",
			coalesced: true,
			activeFingerprint: "fp_active",
		});

		await expect(
			triggerPrReview(payload(), {
				kind: "edited",
				triggerSourceId: "body-new",
				reason: "PR body changed",
			}),
		).resolves.toBeNull();

		expect(mocks.createSession).not.toHaveBeenCalled();
		expect(mocks.sendEvent).not.toHaveBeenCalled();
		const statusPost = mocks.fetch.mock.calls.find(([url]) =>
			String(url).includes(
				"/statuses/deadbeefcafebabe1234567890abcdef12345678",
			),
		);
		expect(statusPost?.[1]).toMatchObject({ method: "POST" });
		expect(JSON.parse(String(statusPost?.[1]?.body))).toMatchObject({
			state: "pending",
			context: "WorkSpaces Managed Review",
			description:
				"Managed reviewer already running; latest trigger coalesced.",
			target_url:
				"https://spaces.cloudcompute.com/dashboard/review-runs/fp_active",
		});
	});

	it("includes prior managed reviews in the kickoff for reruns", async () => {
		mocks.fetch.mockImplementation(async (url: string) => {
			if (url.includes("/pulls?")) {
				return { ok: true, json: async () => [githubPr(8)] };
			}
			if (url.includes("/labels?")) {
				return { ok: true, json: async () => [] };
			}
			if (url.includes("/issues/9/comments?")) {
				return { ok: true, json: async () => [] };
			}
			if (/\/pulls\/9\/reviews\?/.test(url)) {
				return {
					ok: true,
					json: async () => [
						{
							id: 1,
							state: "CHANGES_REQUESTED",
							body: "Need evidence",
							submitted_at: "2026-05-08T10:00:00Z",
							commit_id: "oldsha000000000000",
							user: { login: "workspaces-claude-pr-reviewer[bot]" },
						},
					],
				};
			}
			if (/\/pulls\/8\/reviews\?/.test(url)) {
				return { ok: true, json: async () => [] };
			}
			if (isManagedReviewStatusUrl(url)) {
				return okResponse();
			}
			throw new Error(`Unexpected fetch URL: ${url}`);
		});

		await expect(
			triggerPrReview(payload(), {
				kind: "synchronize",
				triggerSourceId: "deadbeefcafebabe1234567890abcdef12345678",
				reason: "New commit pushed (head deadbeef)",
			}),
		).resolves.toBe("sesn_01");

		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(message).toContain("Rerun context (trusted)");
		expect(message).toContain("This rerun fired because: New commit pushed");
		expect(message).toContain(
			'<untrusted-content name="prior-managed-reviews">',
		);
		expect(message).toContain("Need evidence");
		expect(message).toContain("older head");
	});

	it("records run failure when session creation throws", async () => {
		mockPrList([githubPr(9)]);
		mocks.createSession.mockRejectedValueOnce(new Error("session denied"));

		await expect(triggerPrReview(payload())).rejects.toThrow("session denied");

		expect(mocks.recordRunResult).toHaveBeenCalledWith(
			"fp_test",
			expect.objectContaining({
				status: "failed",
				sessionId: null,
				error: "session denied",
			}),
		);
	});

	it("shapes the kickoff as a follow-up when a prior managed review exists", async () => {
		mocks.fetch.mockImplementation(async (url: string) => {
			if (url.includes("/pulls?")) {
				return { ok: true, json: async () => [githubPr(8)] };
			}
			if (url.includes("/labels?")) {
				return { ok: true, json: async () => [] };
			}
			if (url.includes("/issues/9/comments?")) {
				return { ok: true, json: async () => [] };
			}
			if (/\/pulls\/9\/reviews\?/.test(url)) {
				return {
					ok: true,
					json: async () => [
						{
							id: 9011,
							state: "CHANGES_REQUESTED",
							body: "Need evidence for the Settings injection bug.",
							submitted_at: "2026-05-07T14:51:31Z",
							commit_id: "149919136973eeb166d827278c636e3fc45b21bb",
							user: { login: "workspaces-claude-pr-reviewer[bot]" },
						},
					],
				};
			}
			if (/\/pulls\/8\/reviews\?/.test(url)) {
				return { ok: true, json: async () => [] };
			}
			if (isManagedReviewStatusUrl(url)) {
				return okResponse();
			}
			throw new Error(`Unexpected fetch URL: ${url}`);
		});

		await expect(
			triggerPrReview(
				payload({ headSha: "4c38cbdf3ffe88502c66ee7c74776e6c27d3312d" }),
				{
					kind: "synchronize",
					triggerSourceId: "4c38cbdf3ffe88502c66ee7c74776e6c27d3312d",
					reason: "New commit pushed",
				},
			),
		).resolves.toBe("sesn_01");

		const sessionRequest = mocks.createSession.mock.calls[0][0];
		expect(sessionRequest.title).toMatch(/^Re-review PR #9:/);
		expect(sessionRequest.metadata).toMatchObject({
			run_kind: "follow-up",
			trigger_kind: "synchronize",
		});

		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(message).toContain("You reviewed this PR before");
		expect(message).toContain(
			"Anchor commit (your last review): 149919136973eeb166d827278c636e3fc45b21bb",
		);
		expect(message).toContain(
			"git diff 149919136973eeb166d827278c636e3fc45b21bb..HEAD",
		);
		expect(message).toContain("Anchor on what changed since your last review");
		expect(message).toContain("## Follow-up review format");
		expect(message).toContain("## Changes Since Last Review");
		expect(message).toContain("**Resolved:**");
		expect(message).toContain("**New:**");
		expect(message).toContain(
			"Prior blockers addressed; nothing new of concern",
		);
		expect(message).toContain(
			"`## Project Thread` section is optional on reruns",
		);
	});

	it("uses the initial kickoff when a rerun has no recoverable prior review", async () => {
		mocks.fetch.mockImplementation(async (url: string) => {
			if (url.includes("/pulls?")) {
				return { ok: true, json: async () => [githubPr(8)] };
			}
			if (url.includes("/labels?")) {
				return { ok: true, json: async () => [] };
			}
			if (url.includes("/issues/9/comments?")) {
				return { ok: true, json: async () => [] };
			}
			if (/\/pulls\/\d+\/reviews\?/.test(url)) {
				return { ok: true, json: async () => [] };
			}
			if (isManagedReviewStatusUrl(url)) {
				return okResponse();
			}
			throw new Error(`Unexpected fetch URL: ${url}`);
		});

		await expect(
			triggerPrReview(payload(), {
				kind: "synchronize",
				triggerSourceId: "newsha",
				reason: "New commit pushed",
			}),
		).resolves.toBe("sesn_01");

		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		// Still includes follow-up output-format trailer (this is a rerun)
		expect(message).toContain("## Follow-up review format");
		// But without a recoverable prior review, no anchor commit / git diff line
		expect(message).not.toContain("Anchor commit (your last review):");
		expect(message).toContain(
			"rerun without a recoverable prior review on this PR",
		);
	});

	it("omits the follow-up trailer entirely on the initial run", async () => {
		mockPrList([githubPr(9), githubPr(8)]);

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		const sessionRequest = mocks.createSession.mock.calls[0][0];
		expect(sessionRequest.title).toMatch(/^Review PR #9:/);
		expect(sessionRequest.metadata).toMatchObject({ run_kind: "initial" });

		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(message).not.toContain("## Follow-up review format");
		expect(message).not.toContain("## Changes Since Last Review");
		expect(message).not.toContain("Rerun context (trusted)");
	});
});
