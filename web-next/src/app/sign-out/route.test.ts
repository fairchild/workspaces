/*
 * The local-mode exit contract (#1488). The claim under test is the one the
 * broken button could not make: after sign-out the browser is genuinely
 * signed out, so /sign-in shows its door instead of bouncing home. Each test
 * runs the response's Set-Cookie through a browser-shaped cookie jar and asks
 * the real gates — getAuthState, which is the sign-in page's whole redirect
 * decision, and the real middleware — what they make of the next request.
 */
import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { getAuthState } from "@/lib/auth/auth-state";
import { LOCAL_AUTH_COOKIE, TEST_AUTH_COOKIE } from "@/lib/auth/config";
import { middleware } from "@/middleware";
import { POST } from "./route";

const TOKEN = "the-minted-token";

/** Cookies the browser is holding; the next/headers mock reads this. */
let jar = new Map<string, string>();

vi.mock("next/headers", () => ({
	cookies: async () => ({
		get: (name: string) => {
			const value = jar.get(name);
			return value === undefined ? undefined : { name, value };
		},
	}),
	headers: async () => new Headers(),
}));

function cookieHeader(): string {
	return [...jar].map(([name, value]) => `${name}=${value}`).join("; ");
}

/**
 * Applies one Set-Cookie the way a browser would, so everything after it is
 * asserted against the cookies the *next* request carries. An expired cookie
 * leaves the jar rather than sitting in it empty — clearing by expiry is the
 * whole mechanism here.
 */
function applySetCookie(header: string): void {
	const [pair, ...attributes] = header.split(";").map((part) => part.trim());
	const separator = pair.indexOf("=");
	const name = pair.slice(0, separator);
	const expired = attributes.some(
		(attribute) =>
			/^max-age=0$/i.test(attribute) ||
			(/^expires=/i.test(attribute) && new Date(attribute.slice(8)) <= new Date()),
	);
	if (expired) jar.delete(name);
	else jar.set(name, pair.slice(separator + 1));
}

/** Everything the old client-side handler could reach — never the HttpOnly one. */
function clearScriptReachableCookies(): void {
	jar.delete(TEST_AUTH_COOKIE);
	jar.delete("better-auth.session_token");
}

function signOutRequest(
	host = "localhost:3100",
	headers: Record<string, string> = {},
): NextRequest {
	return new NextRequest("http://localhost:3100/sign-out", {
		method: "POST",
		headers: { host, cookie: cookieHeader(), ...headers },
	});
}

describe("POST /sign-out", () => {
	beforeEach(() => {
		jar = new Map([
			[LOCAL_AUTH_COOKIE, TOKEN],
			[TEST_AUTH_COOKIE, "fairchild"],
		]);
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "1");
		vi.stubEnv("WEB_NEXT_LOCAL_TOKEN", TOKEN);
		vi.stubEnv("WEB_NEXT_LOCAL_LOGIN", "fairchild");
		vi.stubEnv("AUTH_BYPASS", "");
		vi.stubEnv("GITHUB_OAUTH_CLIENT_ID", "");
		vi.stubEnv("WEB_NEXT_EXTRA_LOCAL_ORIGINS", "");
	});

	afterEach(() => {
		vi.unstubAllEnvs();
	});

	test("expires the session cookie and sends the browser to /sign-in", async () => {
		const response = await POST(signOutRequest());
		expect(response.status).toBe(303);
		// Relative on purpose: an absolute target built from the server's own
		// request.url would send a tailnet phone to its own loopback.
		expect(response.headers.get("location")).toBe("/sign-in");
		const setCookie = response.headers.get("set-cookie") ?? "";
		expect(setCookie).toContain(`${LOCAL_AUTH_COOKIE}=;`);
		expect(setCookie).toContain("Max-Age=0");
		expect(setCookie).toContain("Path=/");
		expect(setCookie).toContain("HttpOnly");
	});

	test("leaves the browser signed out, so /sign-in renders instead of bouncing home", async () => {
		const response = await POST(signOutRequest());
		applySetCookie(response.headers.get("set-cookie") ?? "");

		expect(jar.has(LOCAL_AUTH_COOKIE)).toBe(false);
		// `if (auth.kind !== "unauthenticated") redirect("/")` is the sign-in
		// page's whole bounce decision, so this verdict is the page's.
		await expect(getAuthState()).resolves.toEqual({ kind: "unauthenticated" });

		// And the edge serves /sign-in to that browser rather than intercepting.
		const signIn = await middleware(
			new NextRequest("http://localhost:3100/sign-in", {
				headers: { host: "localhost:3100", cookie: cookieHeader() },
			}),
		);
		expect(signIn.headers.get("x-middleware-next")).toBe("1");
	});

	test("clearing only the script-reachable cookies leaves the session up — the bug", async () => {
		// What the button did before: the local session survived, so /sign-in
		// bounced home and the control looked inert. Pinned so the assertion
		// above cannot pass for the wrong reason.
		clearScriptReachableCookies();
		await expect(getAuthState()).resolves.toEqual({
			kind: "authorized",
			user: { login: "fairchild", name: "fairchild" },
		});
	});

	test("carries Secure over the tailnet origin, matching the mint", async () => {
		vi.stubEnv("WEB_NEXT_EXTRA_LOCAL_ORIGINS", "https://mac.tail.ts.net");
		const response = await POST(
			signOutRequest("mac.tail.ts.net", { "x-forwarded-proto": "https" }),
		);
		expect(response.headers.get("set-cookie")).toContain("Secure");
	});

	test("404s outside local mode and leaves the browser's cookies alone", async () => {
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "");
		const response = await POST(signOutRequest());
		expect(response.status).toBe(404);
		expect(response.headers.get("set-cookie")).toBeNull();
	});
});
