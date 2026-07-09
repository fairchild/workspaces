/*
 * Covers the repo-directory decision matrix: App credentials always use the
 * real GitHub path, no credentials plus local/bypass use fixtures, and no
 * credentials plus real OAuth stays degraded.
 */
import crypto from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
	isDirectoryDegraded,
	listDirectoryRepos,
	mergeRepoLists,
	resolveRepo,
	RepoUnavailableError,
	validateDirectoryRepo,
} from "./repo-directory";

const { privateKey } = crypto.generateKeyPairSync("rsa", {
	modulusLength: 2048,
	publicKeyEncoding: { type: "spki", format: "pem" },
	privateKeyEncoding: { type: "pkcs8", format: "pem" },
});

afterEach(() => {
	vi.unstubAllGlobals();
	vi.unstubAllEnvs();
});

describe("fixture mode (no App creds plus local or bypass auth)", () => {
	it("lists the deterministic fixture repos, alphabetical", async () => {
		vi.stubEnv("AUTH_BYPASS", "1");
		vi.stubEnv("GITHUB_WEB_WORKSPACES_APP_ID", "");
		vi.stubEnv("GITHUB_APP_PRIVATE_KEY", "");
		await expect(listDirectoryRepos()).resolves.toEqual([
			{ fullName: "fairchild/dotfiles", defaultBranch: "main", private: false },
			{
				fullName: "fairchild/web-next-fixtures",
				defaultBranch: "trunk",
				private: true,
			},
			{ fullName: "fairchild/workspaces", defaultBranch: "main", private: false },
		]);
	});

	it("validates a fixture repo as ok, case-insensitively", async () => {
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "1");
		vi.stubEnv("GITHUB_WEB_WORKSPACES_APP_ID", "");
		vi.stubEnv("GITHUB_APP_PRIVATE_KEY", "");
		await expect(validateDirectoryRepo("Fairchild/Workspaces")).resolves.toEqual({
			kind: "ok",
			fullName: "fairchild/workspaces",
			defaultBranch: "main",
			private: false,
		});
	});

	it("resolves a non-fixture repo as not-found without touching the network", async () => {
		vi.stubEnv("AUTH_BYPASS", "1");
		vi.stubEnv("GITHUB_WEB_WORKSPACES_APP_ID", "");
		vi.stubEnv("GITHUB_APP_PRIVATE_KEY", "");
		const fetchSpy = vi.fn();
		vi.stubGlobal("fetch", fetchSpy);
		await expect(
			validateDirectoryRepo("fairchild/does-not-exist"),
		).resolves.toEqual({ kind: "not-found", fullName: "fairchild/does-not-exist" });
		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it("is never degraded", () => {
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "1");
		vi.stubEnv("GITHUB_WEB_WORKSPACES_APP_ID", "");
		vi.stubEnv("GITHUB_APP_PRIVATE_KEY", "");
		expect(isDirectoryDegraded()).toBe(false);
	});

	it("treats empty-string App credentials as absent for e2e fixture mode", async () => {
		vi.stubEnv("AUTH_BYPASS", "1");
		vi.stubEnv("GITHUB_WEB_WORKSPACES_APP_ID", "");
		vi.stubEnv("GITHUB_APP_PRIVATE_KEY", "");
		await expect(listDirectoryRepos()).resolves.toContainEqual({
			fullName: "fairchild/workspaces",
			defaultBranch: "main",
			private: false,
		});
	});
});

describe("degraded mode (no App creds plus real OAuth)", () => {
	it("lists no repos and accepts freetext as unverified", async () => {
		vi.stubEnv("AUTH_BYPASS", "");
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "");
		vi.stubEnv("GITHUB_OAUTH_CLIENT_ID", "Iv1.real");
		vi.stubEnv("GITHUB_WEB_WORKSPACES_APP_ID", "");
		vi.stubEnv("GITHUB_APP_PRIVATE_KEY", "");
		expect(isDirectoryDegraded()).toBe(true);
		await expect(listDirectoryRepos()).resolves.toEqual([]);
		await expect(validateDirectoryRepo("fairchild/workspaces")).resolves.toEqual({
			kind: "unverified",
			fullName: "fairchild/workspaces",
		});
		await expect(resolveRepo("fairchild/workspaces")).resolves.toEqual({
			defaultBranch: null,
		});
	});

	it("does not let a leaked bypass flag activate fixtures when real OAuth is configured", async () => {
		vi.stubEnv("AUTH_BYPASS", "1");
		vi.stubEnv("GITHUB_OAUTH_CLIENT_ID", "Iv1.real");
		vi.stubEnv("GITHUB_WEB_WORKSPACES_APP_ID", "");
		vi.stubEnv("GITHUB_APP_PRIVATE_KEY", "");
		expect(isDirectoryDegraded()).toBe(true);
		await expect(listDirectoryRepos()).resolves.toEqual([]);
	});
});

describe("configured mode (App creds present, GitHub mocked)", () => {
	function stubEnv() {
		vi.stubEnv("AUTH_BYPASS", "");
		vi.stubEnv("GITHUB_WEB_WORKSPACES_APP_ID", "123456");
		vi.stubEnv("GITHUB_APP_PRIVATE_KEY", privateKey);
	}

	it("validates an accessible repo as ok with its real default branch", async () => {
		stubEnv();
		vi.stubGlobal(
			"fetch",
			vi.fn(async (input: RequestInfo | URL) => {
				const url = String(input);
				if (url.endsWith("/repos/fairchild/workspaces/installation")) {
					return Response.json({ id: 99 });
				}
				if (url.endsWith("/app/installations/99/access_tokens")) {
					return Response.json({
						token: "ghs_token",
						expires_at: "2026-01-01T00:00:00Z",
						permissions: { contents: "read" },
					});
				}
				if (url.endsWith("/repos/fairchild/workspaces")) {
					return Response.json({
						full_name: "fairchild/workspaces",
						default_branch: "main",
						private: false,
					});
				}
				throw new Error(`unexpected fetch: ${url}`);
			}),
		);
		await expect(resolveRepo("fairchild/workspaces")).resolves.toEqual({
			defaultBranch: "main",
		});
	});

	it("rejects a repo that doesn't exist (no installation covers it)", async () => {
		stubEnv();
		vi.stubGlobal(
			"fetch",
			vi.fn(async () => new Response("not found", { status: 404 })),
		);
		await expect(resolveRepo("fairchild/does-not-exist")).rejects.toBeInstanceOf(
			RepoUnavailableError,
		);
	});

	it("rejects a repo the installation can't read, even once a token is minted", async () => {
		stubEnv();
		vi.stubGlobal(
			"fetch",
			vi.fn(async (input: RequestInfo | URL) => {
				const url = String(input);
				if (url.endsWith("/installation")) return Response.json({ id: 99 });
				if (url.endsWith("/access_tokens")) {
					return Response.json({
						token: "ghs_token",
						expires_at: "2026-01-01T00:00:00Z",
						permissions: {},
					});
				}
				// The repo-read call: access revoked / private and not granted.
				return new Response("not found", { status: 404 });
			}),
		);
		await expect(
			resolveRepo("fairchild/no-longer-granted"),
		).rejects.toBeInstanceOf(RepoUnavailableError);
	});

	it("lists the installation's repos via the directory token", async () => {
		stubEnv();
		vi.stubGlobal(
			"fetch",
			vi.fn(async (input: RequestInfo | URL) => {
				const url = String(input);
				if (url.endsWith("/app/installations")) {
					return Response.json([{ id: 7, account: { login: "fairchild" } }]);
				}
				if (url.endsWith("/app/installations/7/access_tokens")) {
					return Response.json({
						token: "ghs_dir_token",
						expires_at: "2026-01-01T00:00:00Z",
						permissions: {},
					});
				}
				if (url.includes("/installation/repositories")) {
					return Response.json({
						repositories: [
							{
								full_name: "fairchild/zeta",
								default_branch: "main",
								private: false,
							},
							{
								full_name: "fairchild/alpha",
								default_branch: "main",
								private: false,
							},
						],
					});
				}
				throw new Error(`unexpected fetch: ${url}`);
			}),
		);
		await expect(listDirectoryRepos()).resolves.toEqual([
			{ fullName: "fairchild/alpha", defaultBranch: "main", private: false },
			{ fullName: "fairchild/zeta", defaultBranch: "main", private: false },
		]);
	});

	it("uses real App credentials even under AUTH_BYPASS", async () => {
		stubEnv();
		vi.stubEnv("AUTH_BYPASS", "1");
		vi.stubGlobal(
			"fetch",
			vi.fn(async (input: RequestInfo | URL) => {
				const url = String(input);
				if (url.endsWith("/app/installations")) {
					return Response.json([{ id: 7, account: { login: "fairchild" } }]);
				}
				if (url.endsWith("/app/installations/7/access_tokens")) {
					return Response.json({
						token: "ghs_dir_token",
						expires_at: "2026-01-01T00:00:00Z",
						permissions: {},
					});
				}
				if (url.includes("/installation/repositories")) {
					return Response.json({
						repositories: [
							{
								full_name: "fairchild/real-from-app",
								default_branch: "main",
								private: true,
							},
						],
					});
				}
				throw new Error(`unexpected fetch: ${url}`);
			}),
		);
		await expect(listDirectoryRepos()).resolves.toEqual([
			{
				fullName: "fairchild/real-from-app",
				defaultBranch: "main",
				private: true,
			},
			]);
	});

	it("uses real App credentials even under local mode", async () => {
		stubEnv();
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "1");
		vi.stubGlobal(
			"fetch",
			vi.fn(async (input: RequestInfo | URL) => {
				const url = String(input);
				if (url.endsWith("/app/installations")) {
					return Response.json([{ id: 7, account: { login: "fairchild" } }]);
				}
				if (url.endsWith("/app/installations/7/access_tokens")) {
					return Response.json({
						token: "ghs_dir_token",
						expires_at: "2026-01-01T00:00:00Z",
						permissions: {},
					});
				}
				if (url.includes("/installation/repositories")) {
					return Response.json({
						repositories: [
							{
								full_name: "fairchild/local-but-real",
								default_branch: "main",
								private: true,
							},
						],
					});
				}
				throw new Error(`unexpected fetch: ${url}`);
			}),
		);
		await expect(listDirectoryRepos()).resolves.toEqual([
			{
				fullName: "fairchild/local-but-real",
				defaultBranch: "main",
				private: true,
			},
		]);
	});
});

describe("mergeRepoLists", () => {
	it("keeps connected-only repos so one-click rows survive an empty directory", () => {
		expect(
			mergeRepoLists(
				[],
				[{ fullName: "fairchild/unverified", defaultBranch: null }],
			),
		).toEqual([{ fullName: "fairchild/unverified", defaultBranch: null }]);
	});

	it("dedupes by name (case-insensitive), the directory's fresher branch winning", () => {
		expect(
			mergeRepoLists(
				[{ fullName: "fairchild/workspaces", defaultBranch: "trunk", private: false }],
				[
					{ fullName: "Fairchild/Workspaces", defaultBranch: "main" },
					{ fullName: "fairchild/alpha", defaultBranch: null },
				],
			),
		).toEqual([
			{ fullName: "fairchild/alpha", defaultBranch: null },
			{ fullName: "fairchild/workspaces", defaultBranch: "trunk" },
		]);
	});

	it("sorts the union alphabetically", () => {
		const merged = mergeRepoLists(
			[{ fullName: "b/b", defaultBranch: "main", private: false }],
			[
				{ fullName: "c/c", defaultBranch: null },
				{ fullName: "a/a", defaultBranch: null },
			],
		);
		expect(merged.map((repo) => repo.fullName)).toEqual(["a/a", "b/b", "c/c"]);
	});
});
