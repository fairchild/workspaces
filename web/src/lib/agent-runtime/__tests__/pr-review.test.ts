import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	createSession: vi.fn(),
	sendEvent: vi.fn(),
	uploadFile: vi.fn(),
	getOrCreateAgent: vi.fn(),
	getOrCreateEnvironment: vi.fn(),
	getInstallationToken: vi.fn(),
	fetch: vi.fn(),
	recordRunStart: vi.fn(),
	recordRunResult: vi.fn(),
	computeRunFingerprint: vi.fn(),
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
	computeRunFingerprint: mocks.computeRunFingerprint,
	recordRunStart: mocks.recordRunStart,
	recordRunResult: mocks.recordRunResult,
}));

vi.stubGlobal("fetch", mocks.fetch);

import {
	type PrReviewPayload,
	fetchPrEvidenceContext,
	fetchPrNarrativeContext,
	formatPrEvidenceContext,
	formatPrNarrativeContext,
	parseReviewIntentFromText,
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
	mocks.createSession.mockReset();
	mocks.sendEvent.mockReset();
	mocks.uploadFile.mockReset();
	mocks.getOrCreateAgent.mockReset();
	mocks.getOrCreateEnvironment.mockReset();
	mocks.getInstallationToken.mockReset();
	mocks.fetch.mockReset();
	mocks.recordRunStart.mockReset();
	mocks.recordRunResult.mockReset();
	mocks.computeRunFingerprint.mockReset();

	mocks.getOrCreateAgent.mockResolvedValue("agent_01");
	mocks.getOrCreateEnvironment.mockResolvedValue("env_01");
	mocks.getInstallationToken.mockResolvedValue("ghs_app_token");
	mocks.uploadFile.mockResolvedValue({ id: "file_01" });
	mocks.createSession.mockResolvedValue({ id: "sesn_01" });
	mocks.sendEvent.mockResolvedValue({});
	mocks.computeRunFingerprint.mockReturnValue("fp_test");
	mocks.recordRunStart.mockResolvedValue({ inserted: true });
	mocks.recordRunResult.mockResolvedValue(undefined);
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

	it("rejects unsupported review events", () => {
		expect(() =>
			parseReviewIntentFromText(
				'```json\n{"event":"MERGE","body":"ship it","labels":[]}\n```',
			),
		).toThrow(/unsupported review event/);
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
		expect(prompt).toContain("you do not have write credentials");
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
		expect(message).toContain("do not look for a mounted GitHub token");
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

	it("does not mount GitHub write credentials into the managed-agent session", async () => {
		mockPrList([githubPr(9), githubPr(8)]);

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		expect(mocks.uploadFile).not.toHaveBeenCalled();
		const sessionRequest = mocks.createSession.mock.calls[0][0];
		expect(JSON.stringify(sessionRequest.resources)).not.toContain(
			"github-token",
		);
		expect(JSON.stringify(sessionRequest.resources)).not.toContain(
			"authorization_token",
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
