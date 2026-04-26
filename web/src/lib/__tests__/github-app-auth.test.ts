import crypto from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mockFetch = vi.fn();
vi.stubGlobal("fetch", mockFetch);

import { generateGitHubAppJWT, getInstallationToken } from "../github-app-auth";

const { publicKey, privateKey } = crypto.generateKeyPairSync("rsa", {
	modulusLength: 2048,
	publicKeyEncoding: { type: "spki", format: "pem" },
	privateKeyEncoding: { type: "pkcs8", format: "pem" },
});

describe("generateGitHubAppJWT", () => {
	it("produces a valid RS256 JWT with correct claims", () => {
		const jwt = generateGitHubAppJWT("12345", privateKey);
		const [headerB64, payloadB64, signatureB64] = jwt.split(".");

		const header = JSON.parse(Buffer.from(headerB64, "base64url").toString());
		expect(header).toEqual({ alg: "RS256", typ: "JWT" });

		const payload = JSON.parse(Buffer.from(payloadB64, "base64url").toString());
		expect(payload.iss).toBe("12345");
		expect(payload.exp - payload.iat).toBe(660);

		const data = `${headerB64}.${payloadB64}`;
		const signature = Buffer.from(signatureB64, "base64url");
		const valid = crypto.verify(
			"sha256",
			Buffer.from(data),
			publicKey,
			signature,
		);
		expect(valid).toBe(true);
	});

	it("handles PEM with literal backslash-n sequences", () => {
		const escapedKey = privateKey.replace(/\n/g, "\\n");
		const jwt = generateGitHubAppJWT("99", escapedKey);
		const [headerB64, payloadB64, signatureB64] = jwt.split(".");

		const data = `${headerB64}.${payloadB64}`;
		const signature = Buffer.from(signatureB64, "base64url");
		const valid = crypto.verify(
			"sha256",
			Buffer.from(data),
			publicKey,
			signature,
		);
		expect(valid).toBe(true);
	});
});

describe("getInstallationToken", () => {
	beforeEach(() => {
		mockFetch.mockReset();
	});

	afterEach(() => {
		vi.restoreAllMocks();
	});

	it("returns the installation token on success", async () => {
		mockFetch.mockResolvedValue({
			ok: true,
			json: async () => ({
				token: "ghs_abc123",
				expires_at: "2099-01-01T00:00:00Z",
			}),
		});

		const token = await getInstallationToken("12345", privateKey, "67890");
		expect(token).toBe("ghs_abc123");

		expect(mockFetch).toHaveBeenCalledTimes(1);
		const [url, opts] = mockFetch.mock.calls[0];
		expect(url).toBe(
			"https://api.github.com/app/installations/67890/access_tokens",
		);
		expect(opts.method).toBe("POST");
		expect(opts.headers.Authorization).toMatch(/^Bearer /);
	});

	it("throws on non-2xx response", async () => {
		mockFetch.mockResolvedValue({
			ok: false,
			status: 401,
			text: async () => '{"message":"Bad credentials"}',
		});

		await expect(
			getInstallationToken("12345", privateKey, "67890"),
		).rejects.toThrow("GitHub App token exchange failed (401)");
	});

	it("throws on 403 with useful context", async () => {
		mockFetch.mockResolvedValue({
			ok: false,
			status: 403,
			text: async () => "Resource not accessible by integration",
		});

		await expect(
			getInstallationToken("12345", privateKey, "bad-id"),
		).rejects.toThrow("GitHub App token exchange failed (403)");
	});
});
