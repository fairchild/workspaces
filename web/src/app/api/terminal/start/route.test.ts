import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => {
	const provider = {
		descriptor: {
			id: "vercel-sandbox",
			displayName: "Vercel Sandbox",
			maxSessionDuration: 1800,
			supportsSnapshot: true,
			supportsStreaming: true,
			terminalMode: "pty",
		},
		checkAvailability: vi.fn(),
		createTerminalSandbox: vi.fn(),
	};

	return {
		allowedAgentLogins: new Set(["fairchild"]),
		authorizeRepoAccess: vi.fn(),
		bypassToken: null as string | null,
		createSession: vi.fn(),
		fetchGitHubLogin: vi.fn(),
		getGitHubToken: vi.fn(),
		getSessionForAgent: vi.fn(),
		provider,
		session: { user: { id: "user-1" } } as { user: { id: string } } | null,
	};
});

vi.mock("@/lib/agent-runtime/provider-registry", () => ({
	getRegistry: async () => ({
		getDefault: () => mocks.provider,
		all: () => [mocks.provider],
	}),
}));

vi.mock("@/lib/agent-runtime/config", () => ({
	ALLOWED_AGENT_LOGINS: mocks.allowedAgentLogins,
}));

vi.mock("@/lib/agent-sessions", () => ({
	createSession: mocks.createSession,
	getSessionForAgent: mocks.getSessionForAgent,
}));

vi.mock("@/lib/api-auth", () => ({
	authorizeRepoAccess: mocks.authorizeRepoAccess,
	unauthorizedResponse: () => new Response("unauthorized", { status: 401 }),
}));

vi.mock("@/lib/auth-server", () => ({
	getDevBypassToken: () => mocks.bypassToken,
	getSession: async () => mocks.session,
}));

vi.mock("@/lib/github", () => ({
	fetchGitHubLogin: mocks.fetchGitHubLogin,
	getGitHubToken: mocks.getGitHubToken,
}));

function jsonRequest(body: unknown): Request {
	return new Request("http://localhost/api/terminal/start", {
		method: "POST",
		body: JSON.stringify(body),
	});
}

describe("/api/terminal/start POST", () => {
	beforeEach(() => {
		mocks.allowedAgentLogins.clear();
		mocks.allowedAgentLogins.add("fairchild");
		mocks.authorizeRepoAccess.mockReset();
		mocks.authorizeRepoAccess.mockResolvedValue(null);
		mocks.bypassToken = null;
		mocks.createSession.mockReset();
		mocks.fetchGitHubLogin.mockReset();
		mocks.fetchGitHubLogin.mockResolvedValue("fairchild");
		mocks.getGitHubToken.mockReset();
		mocks.getGitHubToken.mockResolvedValue("oauth-token");
		mocks.getSessionForAgent.mockReset();
		mocks.getSessionForAgent.mockResolvedValue(null);
		mocks.provider.checkAvailability.mockReset();
		mocks.provider.checkAvailability.mockResolvedValue({ available: true });
		mocks.provider.createTerminalSandbox.mockReset();
		mocks.provider.createTerminalSandbox.mockResolvedValue({
			instanceId: "sb-1",
			status: "ready",
		});
		mocks.session = { user: { id: "user-1" } };
	});

	it("passes OAuth auth separately from a token-free clone URL", async () => {
		const { POST } = await import("./route");
		const response = await POST(
			jsonRequest({ repo: "fairchild/workspaces", branch: "main" }),
		);

		expect(response.status).toBe(200);
		expect(mocks.fetchGitHubLogin).toHaveBeenCalledWith("oauth-token");
		expect(mocks.provider.createTerminalSandbox).toHaveBeenCalledWith({
			cloneUrl: "https://github.com/fairchild/workspaces.git",
			authToken: "oauth-token",
			branch: "main",
		});
		const params = mocks.provider.createTerminalSandbox.mock.calls[0][0];
		expect(params.cloneUrl).not.toContain("oauth-token");
		expect(params.cloneUrl).not.toContain("x-access-token");
		expect(mocks.createSession).toHaveBeenCalledWith(
			expect.objectContaining({ userId: "user-1" }),
		);
	});

	it("does not attach the dev bypass placeholder as clone auth", async () => {
		mocks.bypassToken = "dev-bypass-token";

		const { POST } = await import("./route");
		const response = await POST(jsonRequest({ repo: "fairchild/workspaces" }));

		expect(response.status).toBe(200);
		expect(mocks.getGitHubToken).not.toHaveBeenCalled();
		expect(mocks.fetchGitHubLogin).not.toHaveBeenCalled();
		expect(mocks.provider.createTerminalSandbox).toHaveBeenCalledWith({
			cloneUrl: "https://github.com/fairchild/workspaces.git",
			authToken: undefined,
			branch: undefined,
		});
	});

	it("rejects non-allowlisted users before provider work", async () => {
		mocks.fetchGitHubLogin.mockResolvedValue("external-user");

		const { POST } = await import("./route");
		const response = await POST(jsonRequest({ repo: "fairchild/workspaces" }));

		expect(response.status).toBe(403);
		await expect(response.json()).resolves.toEqual({
			error: "Terminal sessions are not yet available for your account",
		});
		expect(mocks.getSessionForAgent).not.toHaveBeenCalled();
		expect(mocks.provider.checkAvailability).not.toHaveBeenCalled();
		expect(mocks.provider.createTerminalSandbox).not.toHaveBeenCalled();
		expect(mocks.createSession).not.toHaveBeenCalled();
	});

	it("does not create a sandbox when repo authorization fails", async () => {
		mocks.authorizeRepoAccess.mockResolvedValue(
			Response.json({ error: "repo not in your workspace" }, { status: 403 }),
		);

		const { POST } = await import("./route");
		const response = await POST(jsonRequest({ repo: "fairchild/workspaces" }));

		expect(response.status).toBe(403);
		expect(mocks.getGitHubToken).not.toHaveBeenCalled();
		expect(mocks.fetchGitHubLogin).not.toHaveBeenCalled();
		expect(mocks.getSessionForAgent).not.toHaveBeenCalled();
		expect(mocks.provider.checkAvailability).not.toHaveBeenCalled();
		expect(mocks.provider.createTerminalSandbox).not.toHaveBeenCalled();
		expect(mocks.createSession).not.toHaveBeenCalled();
	});
});
