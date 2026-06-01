import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
	authorizeRepoAccess: vi.fn(),
	getPrReviewRunByFingerprint: vi.fn(),
	recoverPrReviewRun: vi.fn(),
	session: { user: { id: "user-1" } } as { user: { id: string } } | null,
}));

vi.mock("@/lib/agent-runtime/pr-review-runs", () => ({
	getPrReviewRunByFingerprint: mocks.getPrReviewRunByFingerprint,
}));

vi.mock("@/lib/agent-runtime/pr-review", () => ({
	recoverPrReviewRun: mocks.recoverPrReviewRun,
}));

vi.mock("@/lib/api-auth", () => ({
	authorizeRepoAccess: mocks.authorizeRepoAccess,
	unauthorizedResponse: () =>
		Response.json({ error: "unauthorized" }, { status: 401 }),
}));

vi.mock("@/lib/auth-server", () => ({
	getSession: async () => mocks.session,
}));

const run = {
	fingerprint: "fp_route",
	repoFullName: "fairchild/workspaces",
};

describe("/api/pr-review-runs/[fingerprint]", () => {
	beforeEach(() => {
		mocks.authorizeRepoAccess.mockReset();
		mocks.authorizeRepoAccess.mockResolvedValue(null);
		mocks.getPrReviewRunByFingerprint.mockReset();
		mocks.getPrReviewRunByFingerprint.mockResolvedValue(run);
		mocks.recoverPrReviewRun.mockReset();
		mocks.recoverPrReviewRun.mockResolvedValue({
			ok: true,
			action: "retry_execution",
			outcome: "execution_retry_started",
			fingerprint: "fp_route",
			currentHeadSha: "head-sha",
			message: "Started.",
		});
		mocks.session = { user: { id: "user-1" } };
	});

	it("requires a signed-in user before exposing run details", async () => {
		mocks.session = null;
		const { GET } = await import("./route");

		const response = await GET(new Request("http://localhost"), {
			params: Promise.resolve({ fingerprint: "fp_route" }),
		});

		expect(response.status).toBe(401);
		expect(mocks.getPrReviewRunByFingerprint).not.toHaveBeenCalled();
	});

	it("requires a signed-in user before retry or repair mutation", async () => {
		mocks.session = null;
		const { POST } = await import("./route");

		const response = await POST(
			new Request("http://localhost", { method: "POST" }),
			{
				params: Promise.resolve({ fingerprint: "fp_route" }),
			},
		);

		expect(response.status).toBe(401);
		expect(mocks.getPrReviewRunByFingerprint).not.toHaveBeenCalled();
		expect(mocks.recoverPrReviewRun).not.toHaveBeenCalled();
	});

	it("requires repo access before retry or repair mutation", async () => {
		mocks.authorizeRepoAccess.mockResolvedValue(
			Response.json({ error: "repo not in your workspace" }, { status: 403 }),
		);
		const { POST } = await import("./route");

		const response = await POST(
			new Request("http://localhost", { method: "POST" }),
			{
				params: Promise.resolve({ fingerprint: "fp_route" }),
			},
		);

		expect(response.status).toBe(403);
		expect(mocks.authorizeRepoAccess).toHaveBeenCalledWith(
			"user-1",
			"fairchild/workspaces",
		);
		expect(mocks.recoverPrReviewRun).not.toHaveBeenCalled();
	});

	it("delegates authenticated mutations to the recovery helper", async () => {
		const { POST } = await import("./route");

		const response = await POST(
			new Request("http://localhost", { method: "POST" }),
			{
				params: Promise.resolve({ fingerprint: "fp_route" }),
			},
		);

		expect(response.status).toBe(200);
		expect(mocks.recoverPrReviewRun).toHaveBeenCalledWith("fp_route");
		await expect(response.json()).resolves.toMatchObject({
			ok: true,
			outcome: "execution_retry_started",
		});
	});
});
