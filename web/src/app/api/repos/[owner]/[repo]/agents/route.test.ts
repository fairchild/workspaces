import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	bypassToken: null as string | null,
	isRepoSaved: false,
}));

vi.mock("@/lib/agent-discovery", () => ({
	parseAgentTree: () => ({ agents: [], skills: [], configFiles: [] }),
}));

vi.mock("@/lib/api-auth", () => ({
	authorizeRepoAccess: vi.fn(async () =>
		Response.json({ error: "repo not in your workspace" }, { status: 403 }),
	),
	unauthorizedResponse: () =>
		Response.json({ error: "unauthorized" }, { status: 401 }),
}));

vi.mock("@/lib/auth-server", () => ({
	getDevBypassToken: () => mocks.bypassToken,
	getSession: async () => ({
		user: { id: "user-1" },
		session: { id: "session-1" },
	}),
}));

vi.mock("@/lib/github", () => {
	class GitHubApiError extends Error {
		constructor(
			public status: number,
			public body: string,
		) {
			super(`GitHub API ${status}`);
		}
	}

	return {
		GitHubApiError,
		fetchFileContent: vi.fn(),
		fetchIssuesByLabel: vi.fn(async () => []),
		fetchOpenPRCount: vi.fn(async () => 0),
		fetchRepoTree: vi.fn(async () => []),
		getGitHubToken: vi.fn(async () => "oauth-token"),
	};
});

vi.mock("@/lib/repos", () => ({
	isRepoOwnedByUser: vi.fn(async () => mocks.isRepoSaved),
}));

describe("repo agents route", () => {
	beforeEach(() => {
		mocks.bypassToken = null;
		mocks.isRepoSaved = false;
	});

	it("allows OAuth users to scan repos that are not saved yet", async () => {
		const { GET } = await import("./route");
		const response = await GET(new Request("http://localhost"), {
			params: Promise.resolve({ owner: "fairchild", repo: "workspaces" }),
		});

		expect(response.status).toBe(200);
	});

	it("keeps dev bypass scoped to saved repos", async () => {
		mocks.bypassToken = "dev-bypass-token";

		const { GET } = await import("./route");
		const response = await GET(new Request("http://localhost"), {
			params: Promise.resolve({ owner: "fairchild", repo: "workspaces" }),
		});

		expect(response.status).toBe(403);
	});
});
