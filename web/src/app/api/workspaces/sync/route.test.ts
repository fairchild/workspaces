import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	getSession: vi.fn(),
	getWorkspaces: vi.fn(),
	syncWorkspaces: vi.fn(),
}));

vi.mock("@/lib/api-auth", () => ({
	unauthorizedResponse: () =>
		Response.json({ error: "unauthorized" }, { status: 401 }),
}));

vi.mock("@/lib/auth-server", () => ({
	getSession: mocks.getSession,
}));

vi.mock("@/lib/workspaces", () => ({
	DEFAULT_WORKSPACE_OWNER_ID: "default",
	getWorkspaces: mocks.getWorkspaces,
	syncWorkspaces: mocks.syncWorkspaces,
}));

const originalSyncKey = process.env.WORKSPACE_SYNC_API_KEY;

function restoreEnv(name: string, value: string | undefined): void {
	if (value === undefined) Reflect.deleteProperty(process.env, name);
	else Reflect.set(process.env, name, value);
}

function jsonRequest(body: unknown, token?: string): Request {
	const headers = new Headers({ "content-type": "application/json" });
	if (token) headers.set("authorization", `Bearer ${token}`);
	return new Request("http://localhost/api/workspaces/sync", {
		method: "POST",
		headers,
		body: JSON.stringify(body),
	});
}

function getRequest(token?: string): Request {
	const headers = new Headers();
	if (token) headers.set("authorization", `Bearer ${token}`);
	return new Request("http://localhost/api/workspaces/sync", { headers });
}

function workspace() {
	return {
		id: "ws-1",
		name: "Workspaces",
		path: "/Users/dev/workspaces",
		repoId: null,
		repoName: "fairchild/workspaces",
		createdAt: "2026-01-01T00:00:00Z",
		lastAccessedAt: "2026-01-02T00:00:00Z",
		status: "active",
		gitBranch: "main",
		backendIdentifier: "local",
	};
}

describe("/api/workspaces/sync", () => {
	beforeEach(() => {
		Reflect.set(process.env, "WORKSPACE_SYNC_API_KEY", "sync-secret");
		mocks.getSession.mockReset();
		mocks.getSession.mockResolvedValue({ user: { id: "user-1" } });
		mocks.getWorkspaces.mockReset();
		mocks.getWorkspaces.mockResolvedValue([]);
		mocks.syncWorkspaces.mockReset();
		mocks.syncWorkspaces.mockResolvedValue(1);
	});

	afterEach(() => {
		restoreEnv("WORKSPACE_SYNC_API_KEY", originalSyncKey);
	});

	it("rejects session-authenticated writes without the sync API key", async () => {
		const { POST } = await import("./route");
		const response = await POST(jsonRequest({ workspaces: [workspace()] }));

		expect(response.status).toBe(401);
		expect(mocks.syncWorkspaces).not.toHaveBeenCalled();
	});

	it("accepts writes only with the sync API key and default owner", async () => {
		const { POST } = await import("./route");
		const response = await POST(
			jsonRequest({ workspaces: [workspace()] }, "sync-secret"),
		);

		expect(response.status).toBe(200);
		expect(await response.json()).toEqual({ ok: true, count: 1 });
		expect(mocks.syncWorkspaces).toHaveBeenCalledWith("default", [workspace()]);
	});

	it("scopes session reads to the authenticated user id", async () => {
		const { GET } = await import("./route");
		const response = await GET(getRequest());

		expect(response.status).toBe(200);
		expect(mocks.getWorkspaces).toHaveBeenCalledWith("user-1");
	});

	it("scopes sync API key reads to the default sync owner", async () => {
		const { GET } = await import("./route");
		const response = await GET(getRequest("sync-secret"));

		expect(response.status).toBe(200);
		expect(mocks.getSession).not.toHaveBeenCalled();
		expect(mocks.getWorkspaces).toHaveBeenCalledWith("default");
	});
});
