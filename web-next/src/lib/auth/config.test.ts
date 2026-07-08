import { describe, expect, it } from "vitest";
import {
	authBypassEnabled,
	isLoginAllowed,
	parseAllowedLogins,
	realAuthConfigured,
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
