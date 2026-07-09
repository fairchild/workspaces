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

function localRequestFor(path: string, host = "localhost:3100", cookie?: string): NextRequest {
	return new NextRequest(`http://localhost:3100${path}`, {
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
			error: "local mode only accepts localhost or 127.0.0.1 Host headers",
		});
	});

	it("sets the local session cookie from a valid /sign-in token query", async () => {
		const response = await middleware(localRequestFor("/sign-in?token=local-secret"));
		expect(response.status).toBe(307);
		expect(response.headers.get("location")).toBe("http://localhost:3100/");
		expect(response.headers.get("set-cookie")).toContain(
			"web-next-local-session=local-secret",
		);
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
