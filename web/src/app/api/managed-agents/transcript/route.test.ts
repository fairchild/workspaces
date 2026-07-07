import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	getSessionByInstanceId: vi.fn(),
	getPrReviewRunBySessionId: vi.fn(),
	authorizeRepoAccess: vi.fn(),
	session: { user: { id: "user-1" } } as { user: { id: string } } | null,
	retrieve: vi.fn(),
	eventsList: vi.fn(),
	eventsStream: vi.fn(),
}));

vi.mock("@/lib/agent-sessions", () => ({
	getSessionByInstanceId: mocks.getSessionByInstanceId,
}));

vi.mock("@/lib/agent-runtime/pr-review-runs", () => ({
	getPrReviewRunBySessionId: mocks.getPrReviewRunBySessionId,
}));

vi.mock("@/lib/api-auth", () => ({
	authorizeRepoAccess: mocks.authorizeRepoAccess,
}));

vi.mock("@/lib/auth-server", () => ({
	getSession: async () => mocks.session,
}));

vi.mock("@anthropic-ai/sdk", () => ({
	default: class {
		beta = {
			sessions: {
				retrieve: mocks.retrieve,
				events: {
					list: mocks.eventsList,
					stream: mocks.eventsStream,
				},
			},
		};
	},
}));

async function* asyncIterable<T>(items: T[]): AsyncGenerator<T> {
	for (const item of items) yield item;
}

const toolUseEvent = {
	type: "agent.tool_use",
	id: "ev-1",
	name: "bash",
	input: { command: "ls" },
};

const terminalIdleEvent = {
	type: "session.status_idle",
	id: "ev-idle",
	stop_reason: { type: "end_turn" },
};

function requestFor(sessionId: string): Request {
	return new Request(
		`http://localhost/api/managed-agents/transcript?sessionId=${sessionId}`,
	);
}

describe("/api/managed-agents/transcript", () => {
	beforeEach(() => {
		vi.stubEnv("ANTHROPIC_API_KEY", "test-key");
		mocks.session = { user: { id: "user-1" } };
		mocks.getSessionByInstanceId.mockReset();
		mocks.getSessionByInstanceId.mockResolvedValue(null);
		mocks.getPrReviewRunBySessionId.mockReset();
		mocks.getPrReviewRunBySessionId.mockResolvedValue(null);
		mocks.authorizeRepoAccess.mockReset();
		mocks.authorizeRepoAccess.mockResolvedValue(null);
		mocks.retrieve.mockReset();
		mocks.eventsList.mockReset();
		mocks.eventsList.mockReturnValue(asyncIterable([toolUseEvent]));
		mocks.eventsStream.mockReset();
		mocks.eventsStream.mockResolvedValue(asyncIterable([]));
	});

	it("requires a signed-in user", async () => {
		mocks.session = null;
		const { GET } = await import("./route");

		const response = await GET(requestFor("sess-1"));

		expect(response.status).toBe(401);
	});

	it("ends after backfill for a finished review run without opening a live tail", async () => {
		mocks.getPrReviewRunBySessionId.mockResolvedValue({
			repoFullName: "fairchild/workspaces",
			status: "completed",
		});
		const { GET } = await import("./route");

		const response = await GET(requestFor("sess-1"));
		const body = await response.text();

		expect(body).toContain('"kind":"command"');
		expect(body).toContain("event: end");
		expect(mocks.retrieve).not.toHaveBeenCalled();
		expect(mocks.eventsStream).not.toHaveBeenCalled();
	});

	it("ends a live-tailed review run when the session reaches terminal idle", async () => {
		mocks.getPrReviewRunBySessionId.mockResolvedValue({
			repoFullName: "fairchild/workspaces",
			status: "started",
		});
		mocks.retrieve.mockResolvedValue({ status: "running" });
		mocks.eventsStream.mockResolvedValue(
			asyncIterable([toolUseEvent, terminalIdleEvent]),
		);
		const { GET } = await import("./route");

		const response = await GET(requestFor("sess-1"));
		const body = await response.text();

		expect(mocks.eventsStream).toHaveBeenCalledWith("sess-1");
		expect(body).toContain("event: end");
	});

	it("ends without live tail when the underlying session is terminated", async () => {
		mocks.getSessionByInstanceId.mockResolvedValue({
			repo: "fairchild/workspaces",
		});
		mocks.retrieve.mockResolvedValue({ status: "terminated" });
		const { GET } = await import("./route");

		const response = await GET(requestFor("sess-1"));
		const body = await response.text();

		expect(body).toContain("event: end");
		expect(mocks.eventsStream).not.toHaveBeenCalled();
	});

	it("live-tails an idle chat session so follow-up turns still stream", async () => {
		mocks.getSessionByInstanceId.mockResolvedValue({
			repo: "fairchild/workspaces",
		});
		mocks.retrieve.mockResolvedValue({ status: "idle" });
		const { GET } = await import("./route");

		const response = await GET(requestFor("sess-1"));
		const body = await response.text();

		expect(mocks.eventsStream).toHaveBeenCalledWith("sess-1");
		expect(body).not.toContain("event: end");
	});

	it("bounds the function lifetime as a billing backstop", async () => {
		const { maxDuration } = await import("./route");
		expect(maxDuration).toBe(300);
	});
});
