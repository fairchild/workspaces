import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => {
	const provider = {
		resolveSandboxState: vi.fn(),
	};
	return {
		authSession: { user: { id: "user-1" } } as { user: { id: string } } | null,
		authorizeRepoAccess: vi.fn(),
		consumeTerminalTicket: vi.fn(),
		getSession: vi.fn(),
		issueTerminalTicket: vi.fn(),
		provider,
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
	getSession: mocks.getSession,
}));

vi.mock("@/lib/api-auth", () => ({
	authorizeRepoAccess: mocks.authorizeRepoAccess,
	unauthorizedResponse: () => new Response("unauthorized", { status: 401 }),
}));

vi.mock("@/lib/auth-server", () => ({
	getSession: async () => mocks.authSession,
}));

vi.mock("@/lib/terminal-tickets", () => ({
	consumeTerminalTicket: mocks.consumeTerminalTicket,
	issueTerminalTicket: mocks.issueTerminalTicket,
}));

const baseSession = {
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
};

function jsonRequest(body: unknown): Request {
	return new Request("http://localhost/api/terminal/ticket", {
		method: "POST",
		body: JSON.stringify(body),
	});
}

describe("/api/terminal/ticket", () => {
	beforeEach(() => {
		mocks.authSession = { user: { id: "user-1" } };
		mocks.authorizeRepoAccess.mockReset();
		mocks.authorizeRepoAccess.mockResolvedValue(null);
		mocks.consumeTerminalTicket.mockReset();
		mocks.getSession.mockReset();
		mocks.getSession.mockResolvedValue(baseSession);
		mocks.issueTerminalTicket.mockReset();
		mocks.issueTerminalTicket.mockResolvedValue({
			ticket: "ticket-1",
			expiresAt: "2026-05-04T00:00:30.000Z",
		});
		mocks.provider.resolveSandboxState.mockReset();
		mocks.provider.resolveSandboxState.mockResolvedValue({
			alive: true,
			terminalUrl: "wss://sandbox.example/token/ws",
		});
	});

	it("issues a one-time ticket without returning the durable terminal URL", async () => {
		const { POST } = await import("./route");
		const response = await POST(
			jsonRequest({
				repo: "fairchild/workspaces",
				sessionId: "session-1",
			}),
		);

		expect(response.status).toBe(200);
		await expect(response.json()).resolves.toEqual({
			ticket: "ticket-1",
			expiresAt: "2026-05-04T00:00:30.000Z",
		});
		expect(mocks.issueTerminalTicket).toHaveBeenCalledWith({
			userId: "user-1",
			repo: "fairchild/workspaces",
			sessionId: "session-1",
			computeInstanceId: "sbx-1",
			computeBackend: "vercel-sandbox",
		});
	});

	it("denies a stolen ticket before resolving sandbox state", async () => {
		mocks.consumeTerminalTicket.mockResolvedValue({
			ok: false,
			reason: "wrong-user",
		});

		const { GET } = await import("./route");
		const response = await GET(
			new Request("http://localhost/api/terminal/ticket?ticket=stolen"),
		);

		expect(response.status).toBe(403);
		expect(mocks.provider.resolveSandboxState).not.toHaveBeenCalled();
	});

	it("rejects expired tickets", async () => {
		mocks.consumeTerminalTicket.mockResolvedValue({
			ok: false,
			reason: "expired",
		});

		const { GET } = await import("./route");
		const response = await GET(
			new Request("http://localhost/api/terminal/ticket?ticket=expired"),
		);

		expect(response.status).toBe(410);
	});

	it("does not redeem a ticket into a URL after the session is stopped", async () => {
		mocks.consumeTerminalTicket.mockResolvedValue({
			ok: true,
			ticket: {
				userId: "user-1",
				repo: "fairchild/workspaces",
				sessionId: "session-1",
				computeInstanceId: "sbx-1",
				computeBackend: "vercel-sandbox",
				expiresAt: "2026-05-04T00:00:30.000Z",
				redeemedAt: "2026-05-04T00:00:01.000Z",
			},
		});
		mocks.getSession.mockResolvedValue({
			...baseSession,
			status: "completed",
		});

		const { GET } = await import("./route");
		const response = await GET(
			new Request("http://localhost/api/terminal/ticket?ticket=ticket-1"),
		);

		expect(response.status).toBe(409);
		await expect(response.json()).resolves.toEqual({
			error: "terminal session is not running",
		});
	});
});
