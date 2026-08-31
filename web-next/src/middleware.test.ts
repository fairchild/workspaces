/*
 * Unit coverage for the edge auth gate's API-vs-page response shape (#828):
 * unauthenticated `/api/*` requests get 401 JSON straight from the edge,
 * never an HTML sign-in redirect, while page requests are unaffected.
 * Exercises the real `middleware` export directly against a NextRequest in
 * the deterministic bypass mode (env-stubbed, restored after each test).
 */
import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { middleware } from "./middleware";

const ORIGINAL_ENV = { ...process.env };

function requestFor(path: string, cookie?: string): NextRequest {
	return new NextRequest(`https://spaces.example${path}`, {
		headers: cookie ? { cookie } : {},
	});
}

function localRequestFor(
	path: string,
	host = "localhost:3100",
	cookie?: string,
	origin = "http://localhost:3100",
): NextRequest {
	return new NextRequest(`${origin}${path}`, {
		headers: {
			host,
			...(cookie ? { cookie } : {}),
		},
	});
}

describe("middleware", () => {
	beforeEach(() => {
		process.env.AUTH_BYPASS = "1";
		delete process.env.GITHUB_OAUTH_CLIENT_ID;
	});

	afterEach(() => {
		process.env = { ...ORIGINAL_ENV };
	});

	it("answers an unauthenticated /api/* request with 401 JSON, not a redirect", async () => {
		const response = await middleware(requestFor("/api/sessions/any/chat"));
		expect(response.status).toBe(401);
		expect(response.headers.get("location")).toBeNull();
		expect(response.headers.get("content-type")).toContain("application/json");
		await expect(response.json()).resolves.toEqual({
			error: "not signed in as the allowed user",
		});
	});

	it("still redirects an unauthenticated page request to /sign-in", async () => {
		const response = await middleware(requestFor("/"));
		expect(response.status).toBe(307);
		expect(response.headers.get("location")).toContain("/sign-in");
	});

	it("lets a valid bypass cookie through for both /api and page paths", async () => {
		const cookie = "test-auth-login=fairchild";
		const apiResponse = await middleware(requestFor("/api/repos", cookie));
		expect(apiResponse.headers.get("x-middleware-next")).toBe("1");
		const pageResponse = await middleware(requestFor("/", cookie));
		expect(pageResponse.headers.get("x-middleware-next")).toBe("1");
	});

	it("passes /api/auth/* through unauthenticated — already public", async () => {
		const response = await middleware(requestFor("/api/auth/session"));
		expect(response.headers.get("x-middleware-next")).toBe("1");
	});

	it("passes /api/healthz through unauthenticated — the readiness probe is public", async () => {
		const response = await middleware(requestFor("/api/healthz"));
		expect(response.headers.get("x-middleware-next")).toBe("1");
	});

	it("does not extend healthz's public grant to nested paths", async () => {
		const response = await middleware(requestFor("/api/healthz/debug"));
		expect(response.status).toBe(401);
	});
});

describe("middleware local mode", () => {
	beforeEach(() => {
		process.env.WEB_NEXT_LOCAL_MODE = "1";
		process.env.WEB_NEXT_LOCAL_TOKEN = "local-secret";
		delete process.env.AUTH_BYPASS;
		delete process.env.GITHUB_OAUTH_CLIENT_ID;
	});

	afterEach(() => {
		process.env = { ...ORIGINAL_ENV };
	});

	it("rejects non-loopback Host headers before serving local mode", async () => {
		const response = await middleware(localRequestFor("/api/repos", "spaces.example"));
		expect(response.status).toBe(403);
		await expect(response.json()).resolves.toEqual({
			error: "local mode only accepts loopback or allowlisted Host headers",
		});
	});

	it("refuses a hostile Host on a dotted /api/auth path — the credential route", async () => {
		// The gate half of #1467. Calling `middleware` directly bypasses the
		// matcher, so this passes before the matcher fix too; it is here to pin
		// that the gate refuses this path once it reaches it. Whether it reaches
		// it is middleware.matcher.test.ts's job, and that is the half that was
		// red. /api/auth/* is public, but the local-mode Host check runs before
		// isPublic(), so a spoofed Host is refused ahead of Better Auth.
		const response = await middleware(
			localRequestFor("/api/auth/callback/foo.bar", "evil.example"),
		);
		expect(response.status).toBe(403);
		await expect(response.json()).resolves.toEqual({
			error: "local mode only accepts localhost or 127.0.0.1 Host headers",
		});
	});

	it("rejects malformed loopback-looking Host headers", async () => {
		for (const host of [
			"localhost:3100:evil",
			"[::1]:bad",
			"localhost.attacker.test",
		]) {
			const response = await middleware(localRequestFor("/api/repos", host));
			expect(response.status).toBe(403);
		}
	});

	it("sets the local session cookie from a valid /sign-in token query", async () => {
		const response = await middleware(localRequestFor("/sign-in?token=local-secret"));
		expect(response.status).toBe(307);
		expect(response.headers.get("location")).toBe("http://localhost:3100/");
		expect(response.headers.get("set-cookie")).toContain(
			"web-next-local-session=local-secret",
		);
	});

	it("honors a safe relative ?redirect= on local sign-in", async () => {
		const response = await middleware(
			localRequestFor("/sign-in?token=local-secret&redirect=/sessions/abc-123"),
		);
		expect(response.status).toBe(307);
		expect(response.headers.get("location")).toBe(
			"http://localhost:3100/sessions/abc-123",
		);
		expect(response.headers.get("set-cookie")).toContain(
			"web-next-local-session=local-secret",
		);
	});

	it("neutralizes encoded control characters in ?redirect= — the WHATWG-strip exploit", async () => {
		// searchParams.get() decodes %09/%0A/%0D; without the control-char
		// reject + origin backstop, new URL("/\t/evil.com/path", origin)
		// resolves to http://evil.com/path (codex review of #1030, confirmed
		// live). Raw query form, exactly as a hostile link would send it.
		for (const encoded of [
			"%2F%09%2Fevil.com%2Fpath",
			"%2F%0A%2Fevil.com",
			"%2F%0D%2Fevil.com",
		]) {
			const response = await middleware(
				localRequestFor(`/sign-in?token=local-secret&redirect=${encoded}`),
			);
			expect(response.status, encoded).toBe(307);
			expect(response.headers.get("location"), encoded).toBe(
				"http://localhost:3100/",
			);
		}
	});

	it("falls back to / for unsafe or empty ?redirect= targets", async () => {
		for (const target of [
			"//evil.com",
			"/\\evil.com",
			"/foo\\bar",
			"https://evil.com",
			"evil.com",
			"",
		]) {
			const response = await middleware(
				localRequestFor(
					`/sign-in?token=local-secret&redirect=${encodeURIComponent(target)}`,
				),
			);
			expect(response.status, target).toBe(307);
			expect(response.headers.get("location"), target).toBe(
				"http://localhost:3100/",
			);
		}
	});

	it("passes /api/healthz through without a local session cookie", async () => {
		const response = await middleware(localRequestFor("/api/healthz"));
		expect(response.headers.get("x-middleware-next")).toBe("1");
	});

	it("redirects local sign-in accepts to the validated Host origin", async () => {
		const response = await middleware(
			localRequestFor(
				"/sign-in?token=local-secret",
				"localhost:3100",
				undefined,
				"http://attacker.test",
			),
		);
		expect(response.status).toBe(307);
		expect(response.headers.get("location")).toBe("http://localhost:3100/");
	});

	it("does not accept a wrong local token", async () => {
		const response = await middleware(localRequestFor("/api/repos", "localhost:3100"));
		expect(response.status).toBe(401);
		const forged = await middleware(
			localRequestFor(
				"/api/repos",
				"localhost:3100",
				"web-next-local-session=wrong",
			),
		);
		expect(forged.status).toBe(401);
	});

	it("lets a valid local session cookie through and ignores the test bypass cookie", async () => {
		const response = await middleware(
			localRequestFor(
				"/api/repos",
				"localhost:3100",
				"web-next-local-session=local-secret",
			),
		);
		expect(response.headers.get("x-middleware-next")).toBe("1");

		const bypass = await middleware(
			localRequestFor("/api/repos", "localhost:3100", "test-auth-login=fairchild"),
		);
		expect(bypass.status).toBe(401);
	});
});

describe("middleware local mode behind a trusted proxy", () => {
	beforeEach(() => {
		process.env.WEB_NEXT_LOCAL_MODE = "1";
		process.env.WEB_NEXT_LOCAL_TOKEN = "local-secret";
		process.env.WEB_NEXT_EXTRA_LOCAL_ORIGINS = "https://mac.tail.ts.net";
		delete process.env.AUTH_BYPASS;
		delete process.env.GITHUB_OAUTH_CLIENT_ID;
	});

	afterEach(() => {
		process.env = { ...ORIGINAL_ENV };
	});

	function proxiedRequestFor(path: string, proto: string | null = "https"): NextRequest {
		return new NextRequest(`https://mac.tail.ts.net${path}`, {
			headers: {
				host: "mac.tail.ts.net",
				...(proto ? { "x-forwarded-proto": proto } : {}),
			},
		});
	}

	it("redirects local sign-in to the proxied https origin with a Secure cookie", async () => {
		const response = await middleware(
			proxiedRequestFor("/sign-in?token=local-secret"),
		);
		expect(response.status).toBe(307);
		expect(response.headers.get("location")).toBe(
			"https://mac.tail.ts.net/api/pairing/redeemed?next=%2F",
		);
		const cookie = response.headers.get("set-cookie") ?? "";
		expect(cookie).toContain("web-next-local-session=local-secret");
		expect(cookie).toContain("Secure");
	});

	it("serves an authenticated request on the allowlisted origin", async () => {
		const response = await middleware(
			proxiedRequestFor("/api/repos?cookiecase", "https"),
		);
		// No cookie yet: unauthenticated, but past the Host gate — 401, not 403.
		expect(response.status).toBe(401);
	});

	it("still 403s the allowlisted host without the proto the allowlist names", async () => {
		const response = await middleware(proxiedRequestFor("/api/repos", null));
		expect(response.status).toBe(403);
	});

	it("still 403s hosts outside the allowlist", async () => {
		const request = new NextRequest("https://evil.tail.ts.net/api/repos", {
			headers: { host: "evil.tail.ts.net", "x-forwarded-proto": "https" },
		});
		expect((await middleware(request)).status).toBe(403);
	});

	it("keeps loopback cookies non-Secure so plain-http localhost still works", async () => {
		const response = await middleware(localRequestFor("/sign-in?token=local-secret"));
		const cookie = response.headers.get("set-cookie") ?? "";
		expect(cookie).toContain("web-next-local-session=local-secret");
		expect(cookie).not.toContain("Secure");
	});

	it("redirects an unauthenticated page to /sign-in on the proxied origin, not loopback", async () => {
		const response = await middleware(proxiedRequestFor("/", "https"));
		expect(response.status).toBe(307);
		expect(response.headers.get("location")).toBe("https://mac.tail.ts.net/sign-in");
	});

	it("serves /api/pairing/ack pre-cookie — the handshake self-authenticates", async () => {
		const response = await middleware(proxiedRequestFor("/api/pairing/ack", "https"));
		expect(response.headers.get("x-middleware-next")).toBe("1");
		const nested = await middleware(proxiedRequestFor("/api/pairing/ack/deeper", "https"));
		expect(nested.status).toBe(401);
	});

	it("403s a userinfo-prefixed Host that would canonicalize onto the allowlist", async () => {
		const request = new NextRequest("https://mac.tail.ts.net/api/repos", {
			headers: { host: "attacker@mac.tail.ts.net", "x-forwarded-proto": "https" },
		});
		expect((await middleware(request)).status).toBe(403);
	});
});
