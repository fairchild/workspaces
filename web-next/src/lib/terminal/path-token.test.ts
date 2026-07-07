import { describe, expect, test } from "vitest";
import { terminalPathToken, terminalTokenSecret } from "./path-token";

describe("terminalPathToken", () => {
	test("is deterministic for a sandbox session id under one secret", () => {
		const env = { TTYD_TOKEN_SECRET: "s3cret" };
		expect(terminalPathToken("vm-1", env)).toBe(terminalPathToken("vm-1", env));
		expect(terminalPathToken("vm-1", env)).toMatch(/^[0-9a-f]{24}$/);
	});

	test("differs across sandbox sessions and across secrets", () => {
		const env = { TTYD_TOKEN_SECRET: "s3cret" };
		expect(terminalPathToken("vm-1", env)).not.toBe(
			terminalPathToken("vm-2", env),
		);
		expect(terminalPathToken("vm-1", env)).not.toBe(
			terminalPathToken("vm-1", { TTYD_TOKEN_SECRET: "other" }),
		);
	});

	test("secret resolution prefers TTYD_TOKEN_SECRET, falls back to BETTER_AUTH_SECRET", () => {
		expect(
			terminalTokenSecret({ TTYD_TOKEN_SECRET: "a", BETTER_AUTH_SECRET: "b" }),
		).toBe("a");
		expect(terminalTokenSecret({ BETTER_AUTH_SECRET: "b" })).toBe("b");
	});

	test("production with no secret refuses; non-production gets the dev fallback", () => {
		expect(() => terminalTokenSecret({ NODE_ENV: "production" })).toThrow(
			/TTYD_TOKEN_SECRET or BETTER_AUTH_SECRET/,
		);
		expect(terminalTokenSecret({ NODE_ENV: "test" })).toBeTruthy();
	});
});
