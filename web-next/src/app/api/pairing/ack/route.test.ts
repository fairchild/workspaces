/*
 * The pairing handshake contract: both verbs authenticate with the minted
 * token and neither trusts network position. POST proves possession in its
 * body and records the ack; GET reports the latest ack to a Bearer-
 * authenticated caller, and never echoes the token back.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { GET, POST } from "./route";

let dataDir: string;

function getRequest(token: string | null = "the-minted-token", host = "localhost:3140"): Request {
	return new Request("http://localhost:3140/api/pairing/ack", {
		headers: {
			host,
			...(token === null ? {} : { authorization: `Bearer ${token}` }),
		},
	});
}

function postRequest(body: unknown): Request {
	return new Request("http://localhost:3140/api/pairing/ack", {
		method: "POST",
		headers: { "content-type": "application/json", "user-agent": "WorkSpaces-iOS-test" },
		body: JSON.stringify(body),
	});
}

describe("/api/pairing/ack", () => {
	beforeEach(() => {
		dataDir = mkdtempSync(path.join(tmpdir(), "pairing-ack-"));
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "1");
		vi.stubEnv("WEB_NEXT_DATA_DIR", dataDir);
		vi.stubEnv("WEB_NEXT_LOCAL_TOKEN", "the-minted-token");
	});

	afterEach(() => {
		vi.unstubAllEnvs();
		rmSync(dataDir, { recursive: true, force: true });
	});

	test("GET reports null before any pairing", async () => {
		await expect(GET(getRequest()).then((r) => r.json())).resolves.toEqual({
			pairedAt: null,
			userAgent: "",
		});
	});

	test("POST with the minted token records an ack GET then reports", async () => {
		const post = await POST(postRequest({ token: "the-minted-token" }));
		expect(post.status).toBe(200);
		const body = await GET(getRequest()).then((r) => r.json());
		expect(body.userAgent).toBe("WorkSpaces-iOS-test");
		expect(typeof body.pairedAt).toBe("string");
		expect(Number.isNaN(Date.parse(body.pairedAt))).toBe(false);
	});

	test("POST rejects a wrong token and records nothing", async () => {
		const post = await POST(postRequest({ token: "wrong" }));
		expect(post.status).toBe(401);
		await expect(GET(getRequest()).then((r) => r.json())).resolves.toEqual({
			pairedAt: null,
			userAgent: "",
		});
	});

	test("POST rejects a body without a token", async () => {
		expect((await POST(postRequest({}))).status).toBe(401);
	});

	test("GET requires the minted token — no bearer, wrong bearer, right bearer", async () => {
		await POST(postRequest({ token: "the-minted-token" }));
		expect((await GET(getRequest(null))).status).toBe(401);
		const wrong = await GET(getRequest("wrong-token"));
		expect(wrong.status).toBe(401);
		await expect(wrong.json()).resolves.toEqual({ error: "invalid pairing token" });
		expect((await GET(getRequest("the-minted-token"))).status).toBe(200);
	});

	test("a spoofed loopback Host does not stand in for the token", async () => {
		// Verified over a real tailnet: `tailscale serve` forwards whatever Host
		// the peer sent, so `Host: localhost` reaches this route from anywhere.
		// Network position must never authorize.
		await POST(postRequest({ token: "the-minted-token" }));
		for (const host of ["localhost:3140", "127.0.0.1:3140", "[::1]:3140"]) {
			expect((await GET(getRequest(null, host))).status, host).toBe(401);
		}
	});

	test("both verbs 404 outside local mode", async () => {
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "");
		expect((await GET(getRequest())).status).toBe(404);
		expect((await POST(postRequest({ token: "the-minted-token" }))).status).toBe(404);
	});
});
