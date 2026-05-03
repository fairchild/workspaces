import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	createSession: vi.fn(),
	sendEvent: vi.fn(),
	uploadFile: vi.fn(),
	getOrCreateAgent: vi.fn(),
	getOrCreateEnvironment: vi.fn(),
	fetch: vi.fn(),
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

vi.stubGlobal("fetch", mocks.fetch);

import {
	type PrReviewPayload,
	fetchPrNarrativeContext,
	triggerPrReview,
} from "../pr-review";

function payload(overrides: Partial<PrReviewPayload> = {}): PrReviewPayload {
	return {
		number: 9,
		title: "Add narrative review context",
		htmlUrl: "https://github.com/fairchild/workspaces/pull/9",
		headRef: "feature/pr-narrative",
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

function mockPrList(prs: unknown[]) {
	mocks.fetch.mockResolvedValue({
		ok: true,
		json: async () => prs,
	});
}

beforeEach(() => {
	vi.stubEnv("ANTHROPIC_API_KEY", "sk-test");
	vi.stubEnv("GITHUB_TOKEN", "ghp_test");
	vi.stubEnv("PR_REVIEWER_MODEL", "claude-test");
	vi.stubEnv("PR_REVIEWER_APP_ID", "");
	vi.stubEnv("PR_REVIEWER_PRIVATE_KEY", "");
	vi.stubEnv("PR_REVIEWER_INSTALLATION_ID", "");
	mocks.createSession.mockReset();
	mocks.sendEvent.mockReset();
	mocks.uploadFile.mockReset();
	mocks.getOrCreateAgent.mockReset();
	mocks.getOrCreateEnvironment.mockReset();
	mocks.fetch.mockReset();

	mocks.getOrCreateAgent.mockResolvedValue("agent_01");
	mocks.getOrCreateEnvironment.mockResolvedValue("env_01");
	mocks.uploadFile.mockResolvedValue({ id: "file_01" });
	mocks.createSession.mockResolvedValue({ id: "sesn_01" });
	mocks.sendEvent.mockResolvedValue({});
});

afterEach(() => {
	vi.unstubAllEnvs();
	vi.restoreAllMocks();
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
			unavailableReason: "GitHub API 500",
		});
		expect(warn).toHaveBeenCalledWith(
			"[pr-review] previous PR context unavailable:",
			"GitHub API 500",
		);
	});
});

describe("triggerPrReview", () => {
	it("configures the review prompt to render details collapsed by default", async () => {
		mockPrList([githubPr(9), githubPr(8)]);

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		expect(mocks.getOrCreateAgent).toHaveBeenCalledTimes(1);
		const [, config] = mocks.getOrCreateAgent.mock.calls[0];
		const prompt = config.systemPrompt;
		expect(prompt).toContain("<details>\n<summary>Details</summary>");
		expect(prompt).toContain(
			"<details><summary>Details</summary> ... </details>",
		);
		expect(prompt).toContain("Do not add the `open` attribute");
		expect(prompt).not.toContain(
			"Use real headings (`## Summary`, `## Details`)",
		);
	});

	it("sends previous PR context and narrative instructions in the kickoff message", async () => {
		mockPrList([githubPr(9), githubPr(8), githubPr(7), githubPr(6)]);

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		expect(mocks.createSession).toHaveBeenCalledTimes(1);
		expect(mocks.sendEvent).toHaveBeenCalledTimes(1);
		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(message).toContain("Previous PR narrative context:");
		expect(message).toContain("Most recently updated PR descriptions");
		expect(message).toContain("PR #8: PR 8");
		expect(message).toContain("Labels: (none)");
		expect(message).toContain("## Project Thread");
		expect(message).toContain("Reference at least one previous PR by number");
	});

	it("instructs the reviewer to apply high-confidence related labels and suggest label opportunities", async () => {
		mockPrList([githubPr(9), githubPr(8, { labels: [{ name: "security" }] })]);

		await expect(triggerPrReview(payload())).resolves.toBe("sesn_01");

		const [, params] = mocks.sendEvent.mock.calls[0];
		const message = params.events[0].content[0].text;
		expect(message).toContain("Labels: security");
		expect(message).toContain(
			"POST https://api.github.com/repos/fairchild/workspaces/issues/9/labels",
		);
		expect(message).toContain(
			"apply that label using the labels endpoint before posting the review",
		);
		expect(message).toContain(
			'Mention the applied label in "## Project Thread"',
		);
		expect(message).toContain("Label suggestion:");
		expect(message).toContain("Do not create labels");
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
