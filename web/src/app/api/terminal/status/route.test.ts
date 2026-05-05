import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => {
	const provider = {
		resolveSandboxState: vi.fn(),
	};
	return {
		authSession: { user: { id: "user-1" } } as { user: { id: string } } | null,
		authorizeRepoAccess: vi.fn(),
		getSessionsForRepo: vi.fn(),
		provider,
		updateSessionStatus: vi.fn(),
	};
});

vi.mock("@/lib/agent-runtime/provider-registry", () => ({
	getRegistry: async () => ({
		get: () => ({
			descriptor: { id: "vercel-sandbox", terminalMode: "pty" },
			resolveSandboxState: mocks.provider.resolveSandboxState,
		}),
	}),
}));

vi.mock("@/lib/agent-sessions", () => ({
	getSessionsForRepo: mocks.getSessionsForRepo,
	updateSessionStatus: mocks.updateSessionStatus,
}));

vi.mock("@/lib/api-auth", () => ({
	authorizeRepoAccess: mocks.authorizeRepoAccess,
	unauthorizedResponse: () => new Response("unauthorized", { status: 401 }),
}));

vi.mock("@/lib/auth-server", () => ({
	getSession: async () => mocks.authSession,
}));

describe("/api/terminal/status GET", () => {
	beforeEach(() => {
		mocks.authSession = { user: { id: "user-1" } };
		mocks.authorizeRepoAccess.mockReset();
		mocks.authorizeRepoAccess.mockResolvedValue(null);
		mocks.getSessionsForRepo.mockReset();
		mocks.getSessionsForRepo.mockResolvedValue([
			{
				id: "session-1",
				userId: "user-1",
				repo: "fairchild/workspaces",
				agentName: "shell",
				computeBackend: "vercel-sandbox",
				computeInstanceId: "sbx-1",
				snapshotId: null,
				claudeSessionId: null,
				threadId: "terminal:user-1:shell:1",
				discussionId: null,
				status: "active",
				createdAt: "2026-05-04T00:00:00.000Z",
				lastActivityAt: "2026-05-04T00:00:00.000Z",
			},
		]);
		mocks.provider.resolveSandboxState.mockReset();
		mocks.provider.resolveSandboxState.mockResolvedValue({
			alive: true,
			terminalUrl: "wss://sandbox.example/token/ws",
		});
		mocks.updateSessionStatus.mockReset();
	});

	it("returns ticket-capable session metadata without the durable terminal URL", async () => {
		const { GET } = await import("./route");
		const response = await GET(
			new Request(
				"http://localhost/api/terminal/status?repo=fairchild%2Fworkspaces",
			),
		);

		expect(response.status).toBe(200);
		const body = await response.json();
		expect(body.sessions).toEqual([
			{
				sessionId: "session-1",
				agentName: "shell",
				state: "running",
				sandboxId: "sbx-1",
				provider: "vercel-sandbox",
				terminalAccess: "ticket",
			},
		]);
		expect(JSON.stringify(body)).not.toContain("wss://sandbox.example");
	});
});
