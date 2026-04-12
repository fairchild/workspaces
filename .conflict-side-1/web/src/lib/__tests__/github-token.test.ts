import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mockExecute = vi.fn();

vi.mock("@/lib/db", () => ({
	getTurso: () => ({ execute: mockExecute }),
}));

const mockFetch = vi.fn();
vi.stubGlobal("fetch", mockFetch);

import { getGitHubToken } from "../github";

function dbRow(overrides: {
	accessToken?: string | null;
	refreshToken?: string | null;
	accessTokenExpiresAt?: string | null;
}) {
	return {
		rows: [
			{
				accessToken:
					overrides.accessToken === undefined
						? "existing-token"
						: overrides.accessToken,
				refreshToken:
					overrides.refreshToken === undefined
						? "existing-refresh"
						: overrides.refreshToken,
				accessTokenExpiresAt: overrides.accessTokenExpiresAt ?? null,
			},
		],
	};
}

function refreshResponse(token = "new-token", refresh = "new-refresh") {
	return {
		ok: true,
		json: async () => ({
			access_token: token,
			refresh_token: refresh,
			expires_in: 28800,
		}),
	};
}

const ONE_HOUR = 60 * 60 * 1000;
const THREE_MIN = 3 * 60 * 1000;
const ONE_MIN = 60 * 1000;

describe("getGitHubToken", () => {
	beforeEach(() => {
		vi.stubEnv("GITHUB_WEB_WORKSPACES_CLIENT_ID", "test-client-id");
		vi.stubEnv("GITHUB_WEB_WORKSPACES_CLIENT_SECRET", "test-secret");
		mockExecute.mockReset();
		mockFetch.mockReset();
	});

	afterEach(() => {
		vi.unstubAllEnvs();
	});

	// --- No refresh needed ---

	it("returns null when no account exists", async () => {
		mockExecute.mockResolvedValue({ rows: [] });

		expect(await getGitHubToken("user-1")).toBeNull();
		expect(mockFetch).not.toHaveBeenCalled();
	});

	it("returns existing token when not expired", async () => {
		const expiresAt = new Date(Date.now() + ONE_HOUR).toISOString();
		mockExecute.mockResolvedValue(dbRow({ accessTokenExpiresAt: expiresAt }));

		expect(await getGitHubToken("user-1")).toBe("existing-token");
		expect(mockFetch).not.toHaveBeenCalled();
		expect(mockExecute).toHaveBeenCalledTimes(1); // SELECT only, no UPDATE
	});

	it("returns existing token when expiresAt is null", async () => {
		mockExecute.mockResolvedValue(dbRow({ accessTokenExpiresAt: null }));

		expect(await getGitHubToken("user-1")).toBe("existing-token");
		expect(mockFetch).not.toHaveBeenCalled();
	});

	// --- Refresh succeeds ---

	it("refreshes and returns new token when expired", async () => {
		const expiresAt = new Date(Date.now() - ONE_MIN).toISOString();
		mockExecute.mockResolvedValue(dbRow({ accessTokenExpiresAt: expiresAt }));
		mockFetch.mockResolvedValue(refreshResponse());

		expect(await getGitHubToken("user-1")).toBe("new-token");

		// Verify DB was updated with new tokens
		expect(mockExecute).toHaveBeenCalledTimes(2);
		const updateCall = mockExecute.mock.calls[1];
		expect(updateCall[0].sql).toContain("UPDATE account SET");
		expect(updateCall[0].args[0]).toBe("new-token");
		expect(updateCall[0].args[1]).toBe("new-refresh");
	});

	it("refreshes proactively when token expires within 5 minutes", async () => {
		const expiresAt = new Date(Date.now() + THREE_MIN).toISOString();
		mockExecute.mockResolvedValue(dbRow({ accessTokenExpiresAt: expiresAt }));
		mockFetch.mockResolvedValue(refreshResponse());

		expect(await getGitHubToken("user-1")).toBe("new-token");
		expect(mockFetch).toHaveBeenCalledTimes(1);
	});

	// --- Refresh fails ---

	it("returns stale token when refresh HTTP request fails", async () => {
		const expiresAt = new Date(Date.now() - ONE_MIN).toISOString();
		mockExecute.mockResolvedValue(dbRow({ accessTokenExpiresAt: expiresAt }));
		mockFetch.mockResolvedValue({ ok: false });

		expect(await getGitHubToken("user-1")).toBe("existing-token");
		expect(mockExecute).toHaveBeenCalledTimes(1); // SELECT only, no UPDATE
	});

	it("returns stale token when refresh returns OAuth error", async () => {
		const expiresAt = new Date(Date.now() - ONE_MIN).toISOString();
		mockExecute.mockResolvedValue(dbRow({ accessTokenExpiresAt: expiresAt }));
		mockFetch.mockResolvedValue({
			ok: true,
			json: async () => ({ error: "bad_refresh_token" }),
		});

		expect(await getGitHubToken("user-1")).toBe("existing-token");
		expect(mockExecute).toHaveBeenCalledTimes(1);
	});

	it("returns stale token when env vars are missing", async () => {
		vi.unstubAllEnvs(); // clear CLIENT_ID and CLIENT_SECRET

		const expiresAt = new Date(Date.now() - ONE_MIN).toISOString();
		mockExecute.mockResolvedValue(dbRow({ accessTokenExpiresAt: expiresAt }));

		expect(await getGitHubToken("user-1")).toBe("existing-token");
		expect(mockFetch).not.toHaveBeenCalled();
	});

	it("returns stale token when no refresh token is stored", async () => {
		const expiresAt = new Date(Date.now() - ONE_MIN).toISOString();
		mockExecute.mockResolvedValue(
			dbRow({ accessTokenExpiresAt: expiresAt, refreshToken: null }),
		);

		expect(await getGitHubToken("user-1")).toBe("existing-token");
		expect(mockFetch).not.toHaveBeenCalled();
	});
});
