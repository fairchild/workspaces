import { describe, expect, it } from "vitest";
import {
	authBypassEnabled,
	assertAuthModeConfig,
	constantTimeEqual,
	isLoopbackHostHeader,
	isLoginAllowed,
	localModeEnabled,
	localSessionCookieValid,
	oauthEnvConfigured,
	parseAllowedLogins,
	realAuthConfigured,
	resolveLocalLogin,
	resolveAuthSecret,
} from "./config";

describe("parseAllowedLogins", () => {
	it("splits, trims, and lowercases the csv", () => {
		expect(
			parseAllowedLogins({ ALLOWED_LOGINS: " Fairchild, some-bot ,," }),
		).toEqual(new Set(["fairchild", "some-bot"]));
	});

	it("is empty when unset — nobody gets in by default", () => {
		expect(parseAllowedLogins({})).toEqual(new Set());
	});
});

describe("isLoginAllowed", () => {
	const env = { ALLOWED_LOGINS: "fairchild" };

	it("matches case-insensitively", () => {
		expect(isLoginAllowed("FairChild", env)).toBe(true);
	});

	it("rejects unknown logins and empty values", () => {
		expect(isLoginAllowed("mallory", env)).toBe(false);
		expect(isLoginAllowed("", env)).toBe(false);
		expect(isLoginAllowed(null, env)).toBe(false);
		expect(isLoginAllowed(undefined, env)).toBe(false);
	});
});

describe("authBypassEnabled (triple lock)", () => {
	it("requires the explicit env var", () => {
		expect(authBypassEnabled({})).toBe(false);
		expect(authBypassEnabled({ AUTH_BYPASS: "0" })).toBe(false);
		expect(authBypassEnabled({ AUTH_BYPASS: "1" })).toBe(true);
	});

	it("is inert whenever a real OAuth app is configured", () => {
		expect(
			authBypassEnabled({
				AUTH_BYPASS: "1",
				GITHUB_OAUTH_CLIENT_ID: "Iv1.real",
			}),
		).toBe(false);
	});

	it("is inert on Vercel even without OAuth config", () => {
		expect(
			authBypassEnabled({
				AUTH_BYPASS: "1",
				VERCEL: "1",
			}),
		).toBe(false);
	});

	it("is inert in local mode", () => {
		expect(
			authBypassEnabled({
				AUTH_BYPASS: "1",
				WEB_NEXT_LOCAL_MODE: "1",
			}),
		).toBe(false);
	});
});

describe("resolveAuthSecret", () => {
	it("prefers the configured secret", () => {
		expect(resolveAuthSecret({ BETTER_AUTH_SECRET: "s3cret" })).toBe("s3cret");
	});

	it("throws when real OAuth is configured without a secret", () => {
		expect(() =>
			resolveAuthSecret({ GITHUB_OAUTH_CLIENT_ID: "Iv1.real" }),
		).toThrow(/BETTER_AUTH_SECRET/);
	});

	it("falls back to a throwaway in test/bypass mode", () => {
		expect(resolveAuthSecret({})).toBeTruthy();
	});
});

describe("realAuthConfigured", () => {
	it("keys on the OAuth client id", () => {
		expect(realAuthConfigured({})).toBe(false);
		expect(realAuthConfigured({ GITHUB_OAUTH_CLIENT_ID: "x" })).toBe(true);
	});
});

describe("local mode config", () => {
	it("resolves explicit local mode and default login", () => {
		expect(localModeEnabled({ WEB_NEXT_LOCAL_MODE: "1" })).toBe(true);
		expect(localModeEnabled({ WEB_NEXT_LOCAL_MODE: "0" })).toBe(false);
		expect(resolveLocalLogin({})).toBe("fairchild");
		expect(resolveLocalLogin({ WEB_NEXT_LOCAL_LOGIN: " Owner " })).toBe("owner");
	});

	it("treats any OAuth var as an OAuth configuration conflict", () => {
		expect(oauthEnvConfigured({})).toBe(false);
		expect(oauthEnvConfigured({ GITHUB_OAUTH_CLIENT_ID: "id" })).toBe(true);
		expect(oauthEnvConfigured({ GITHUB_OAUTH_CLIENT_SECRET: "secret" })).toBe(true);
	});

	it("rejects local-mode conflicts at startup/config time", () => {
		expect(() =>
			assertAuthModeConfig({ WEB_NEXT_LOCAL_MODE: "1", AUTH_BYPASS: "1" }),
		).toThrow(/AUTH_BYPASS/);
		expect(() =>
			assertAuthModeConfig({
				WEB_NEXT_LOCAL_MODE: "1",
				GITHUB_OAUTH_CLIENT_ID: "id",
			}),
		).toThrow(/OAuth/);
		expect(() => assertAuthModeConfig({ WEB_NEXT_LOCAL_MODE: "1" })).not.toThrow();
	});

	it("checks local session cookies with the configured token", () => {
		const env = { WEB_NEXT_LOCAL_MODE: "1", WEB_NEXT_LOCAL_TOKEN: "secret-token" };
		expect(localSessionCookieValid("secret-token", env)).toBe(true);
		expect(localSessionCookieValid("wrong", env)).toBe(false);
		expect(localSessionCookieValid(undefined, env)).toBe(false);
	});

	it("compares strings without accepting prefixes or length mismatches", () => {
		expect(constantTimeEqual("abc", "abc")).toBe(true);
		expect(constantTimeEqual("abc", "abcd")).toBe(false);
		expect(constantTimeEqual("abc", "xbc")).toBe(false);
	});

	it("recognizes loopback Host headers only", () => {
		expect(isLoopbackHostHeader("localhost")).toBe(true);
		expect(isLoopbackHostHeader("localhost:3100")).toBe(true);
		expect(isLoopbackHostHeader("127.0.0.1:3100")).toBe(true);
		expect(isLoopbackHostHeader("[::1]:3100")).toBe(true);
		expect(isLoopbackHostHeader("spaces.example")).toBe(false);
		expect(isLoopbackHostHeader("127.0.0.2:3100")).toBe(false);
		expect(isLoopbackHostHeader(null)).toBe(false);
	});
});
