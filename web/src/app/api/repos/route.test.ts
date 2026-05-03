import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	bypassToken: null as string | null,
	fetchUserRepos: vi.fn(),
	getGitHubToken: vi.fn(),
	session: { user: { id: "user-1" } } as { user: { id: string } } | null,
	setUserRepos: vi.fn(),
}));

vi.mock("@/lib/auth-server", () => ({
	getDevBypassToken: () => mocks.bypassToken,
	getSession: async () => mocks.session,
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
		fetchUserRepos: mocks.fetchUserRepos,
		getGitHubToken: mocks.getGitHubToken,
	};
});

vi.mock("@/lib/repos", () => ({
	getUserRepos: vi.fn(async () => []),
	setUserRepos: mocks.setUserRepos,
}));

function jsonRequest(body: unknown): Request {
	return new Request("http://localhost/api/repos", {
		method: "POST",
		body: JSON.stringify(body),
	});
}

describe("/api/repos POST", () => {
	beforeEach(() => {
		mocks.bypassToken = null;
		mocks.fetchUserRepos.mockReset();
		mocks.fetchUserRepos.mockResolvedValue([
			{
				full_name: "fairchild/workspaces",
				owner: "fairchild",
				name: "workspaces",
				pushed_at: "2026-01-01T00:00:00Z",
				description: null,
			},
			{
				full_name: "Acme/Private-Repo",
				owner: "Acme",
				name: "Private-Repo",
				pushed_at: "2026-01-01T00:00:00Z",
				description: null,
			},
		]);
		mocks.getGitHubToken.mockReset();
		mocks.getGitHubToken.mockResolvedValue("oauth-token");
		mocks.session = { user: { id: "user-1" } };
		mocks.setUserRepos.mockReset();
	});

	it("rejects unauthenticated requests", async () => {
		mocks.session = null;

		const { POST } = await import("./route");
		const response = await POST(jsonRequest({ repos: [] }));

		expect(response.status).toBe(401);
		expect(mocks.setUserRepos).not.toHaveBeenCalled();
	});

	it("rejects repos the authenticated user's GitHub token cannot list", async () => {
		const { POST } = await import("./route");
		const response = await POST(
			jsonRequest({
				repos: [
					{ owner: "fairchild", repo: "workspaces" },
					{ owner: "other", repo: "secret" },
				],
			}),
		);

		expect(response.status).toBe(403);
		expect(await response.json()).toMatchObject({
			error: "repo_not_accessible",
			repos: ["other/secret"],
			needsReauth: true,
		});
		expect(mocks.setUserRepos).not.toHaveBeenCalled();
	});

	it("canonicalizes and dedupes the server-verified GitHub repo list", async () => {
		const { POST } = await import("./route");
		const response = await POST(
			jsonRequest({
				repos: [
					{ owner: "FAIRCHILD", repo: "WORKSPACES" },
					{ owner: "fairchild", repo: "workspaces" },
					{ owner: "acme", repo: "private-repo" },
				],
			}),
		);

		expect(response.status).toBe(200);
		expect(mocks.setUserRepos).toHaveBeenCalledWith("user-1", [
			{ owner: "fairchild", repo: "workspaces" },
			{ owner: "Acme", repo: "Private-Repo" },
		]);
	});

	it("uses the dev bypass token when present", async () => {
		mocks.bypassToken = "dev-token";

		const { POST } = await import("./route");
		const response = await POST(
			jsonRequest({ repos: [{ owner: "fairchild", repo: "workspaces" }] }),
		);

		expect(response.status).toBe(200);
		expect(mocks.getGitHubToken).not.toHaveBeenCalled();
		expect(mocks.fetchUserRepos).toHaveBeenCalledWith("dev-token");
	});

	it("requires GitHub reauth when no OAuth token is available", async () => {
		mocks.getGitHubToken.mockResolvedValue(null);

		const { POST } = await import("./route");
		const response = await POST(
			jsonRequest({ repos: [{ owner: "fairchild", repo: "workspaces" }] }),
		);

		expect(response.status).toBe(403);
		expect(await response.json()).toMatchObject({
			error: "no_github_token",
			needsReauth: true,
		});
		expect(mocks.setUserRepos).not.toHaveBeenCalled();
	});
});
