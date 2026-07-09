import crypto from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
	generateAppJWT,
	getInstallationToken,
	listAppInstallations,
	listInstallationRepositories,
	mintInstallationToken,
	normalizePrivateKey,
} from "./github-app";

// A throwaway RSA keypair — the App private-key handling and RS256 signing are
// the error-prone parts (base64 vs PEM, correct signature), so verify them
// end-to-end without any network.
const { privateKey, publicKey } = crypto.generateKeyPairSync("rsa", {
	modulusLength: 2048,
	publicKeyEncoding: { type: "spki", format: "pem" },
	privateKeyEncoding: { type: "pkcs8", format: "pem" },
});

describe("normalizePrivateKey", () => {
	it("passes a real multi-line PEM through unchanged", () => {
		expect(normalizePrivateKey(privateKey)).toBe(privateKey.trim());
	});

	it("restores newlines from a single-line escaped PEM", () => {
		const escaped = privateKey.trim().replace(/\n/g, "\\n");
		expect(normalizePrivateKey(escaped)).toBe(privateKey.trim());
	});

	it("decodes a base64-encoded PEM (web-next's .env convention)", () => {
		const b64 = Buffer.from(privateKey).toString("base64");
		expect(normalizePrivateKey(b64)).toBe(privateKey);
	});
});

describe("generateAppJWT", () => {
	it("produces a three-part token with a valid RS256 signature and claims", () => {
		const jwt = generateAppJWT("123456", privateKey);
		const [header, payload, signature] = jwt.split(".");
		expect(header && payload && signature).toBeTruthy();

		const verifier = crypto.createVerify("RSA-SHA256");
		verifier.update(`${header}.${payload}`);
		expect(
			verifier.verify(publicKey, Buffer.from(signature, "base64url")),
		).toBe(true);

		const claims = JSON.parse(Buffer.from(payload, "base64url").toString());
		expect(claims.iss).toBe("123456");
		expect(claims.exp - claims.iat).toBe(660); // 10min window + 60s backdate
	});

	it("accepts a base64-encoded key (signature still verifies)", () => {
		const b64 = Buffer.from(privateKey).toString("base64");
		const jwt = generateAppJWT("123456", b64);
		const [header, payload, signature] = jwt.split(".");
		const verifier = crypto.createVerify("RSA-SHA256");
		verifier.update(`${header}.${payload}`);
		expect(
			verifier.verify(publicKey, Buffer.from(signature, "base64url")),
		).toBe(true);
	});
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe("listAppInstallations", () => {
	it("maps the installations list to id + account login", async () => {
		vi.stubGlobal(
			"fetch",
			vi.fn(async () =>
				Response.json([
					{ id: 42, account: { login: "fairchild" } },
					{ id: 43, account: { login: "some-org" } },
				]),
			),
		);
		await expect(listAppInstallations("jwt")).resolves.toEqual([
			{ id: 42, account: "fairchild" },
			{ id: 43, account: "some-org" },
		]);
	});

	it("throws with the response status and body on failure", async () => {
		vi.stubGlobal(
			"fetch",
			vi.fn(async () => new Response("nope", { status: 401 })),
		);
		await expect(listAppInstallations("jwt")).rejects.toThrow(/401/);
	});
});

describe("listInstallationRepositories", () => {
	it("maps the repositories list to fullName/defaultBranch/private", async () => {
		vi.stubGlobal(
			"fetch",
			vi.fn(async () =>
				Response.json({
					repositories: [
						{
							full_name: "fairchild/workspaces",
							default_branch: "main",
							private: false,
						},
						{
							full_name: "fairchild/dotfiles",
							default_branch: "master",
							private: true,
						},
					],
				}),
			),
		);
		await expect(listInstallationRepositories("token")).resolves.toEqual([
			{ fullName: "fairchild/workspaces", defaultBranch: "main", private: false },
			{ fullName: "fairchild/dotfiles", defaultBranch: "master", private: true },
		]);
	});

	it("throws with the response status and body on failure", async () => {
		vi.stubGlobal(
			"fetch",
			vi.fn(async () => new Response("forbidden", { status: 403 })),
		);
		await expect(listInstallationRepositories("token")).rejects.toThrow(/403/);
	});
});

describe("installation token exchange", () => {
	it("pins a repo-scoped write token request for a session repo", async () => {
		vi.stubEnv("GITHUB_WEB_WORKSPACES_APP_ID", "123456");
		vi.stubEnv("GITHUB_APP_PRIVATE_KEY", privateKey);
		let tokenRequestBody: unknown;
		vi.stubGlobal(
			"fetch",
			vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
				const url = String(input);
				if (url.endsWith("/repos/fairchild/workspaces/installation")) {
					return Response.json({ id: 99 });
				}
				if (url.endsWith("/app/installations/99/access_tokens")) {
					tokenRequestBody = JSON.parse(String(init?.body));
					return Response.json({
						token: "ghs_token",
						expires_at: "2026-01-01T00:00:00Z",
						permissions: { contents: "write", pull_requests: "write" },
					});
				}
				throw new Error(`unexpected fetch: ${url}`);
			}),
		);

		await expect(mintInstallationToken("fairchild/workspaces")).resolves.toMatchObject({
			token: "ghs_token",
		});

		expect(tokenRequestBody).toEqual({
			repositories: ["workspaces"],
			permissions: { contents: "write", pull_requests: "write" },
		});
	});

	it("allows callers to ask for a narrower repo-scoped token", async () => {
		let tokenRequestBody: unknown;
		vi.stubGlobal(
			"fetch",
			vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
				const url = String(input);
				if (url.endsWith("/app/installations/7/access_tokens")) {
					tokenRequestBody = JSON.parse(String(init?.body));
					return Response.json({
						token: "ghs_read_token",
						expires_at: "2026-01-01T00:00:00Z",
						permissions: { contents: "read" },
					});
				}
				throw new Error(`unexpected fetch: ${url}`);
			}),
		);

		await expect(
			getInstallationToken("jwt", 7, {
				repo: "fairchild/workspaces",
				permissions: { contents: "read" },
			}),
		).resolves.toMatchObject({ token: "ghs_read_token" });

		expect(tokenRequestBody).toEqual({
			repositories: ["workspaces"],
			permissions: { contents: "read" },
		});
	});
});
