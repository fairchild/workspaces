import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { ttydPathToken } from "../vercel-sandbox";

// process.env.X = undefined sets the env var to the literal string "undefined".
// Reflect.deleteProperty actually removes the key, which is what we want when
// asserting "this env var is unset". Biome's noDelete rule is overly strict
// about delete operators on dynamic properties, so we use Reflect instead.
function unset(name: string): void {
	Reflect.deleteProperty(process.env, name);
}

describe("ttydPathToken", () => {
	const originalSecret = process.env.TTYD_TOKEN_SECRET;
	const originalAuth = process.env.BETTER_AUTH_SECRET;

	beforeEach(() => {
		process.env.TTYD_TOKEN_SECRET = "test-secret-fixed";
		unset("BETTER_AUTH_SECRET");
	});

	afterEach(() => {
		if (originalSecret === undefined) unset("TTYD_TOKEN_SECRET");
		else process.env.TTYD_TOKEN_SECRET = originalSecret;
		if (originalAuth === undefined) unset("BETTER_AUTH_SECRET");
		else process.env.BETTER_AUTH_SECRET = originalAuth;
	});

	it("returns a deterministic 24-char hex string for the same sandbox id", () => {
		const a = ttydPathToken("sbx_abc123");
		const b = ttydPathToken("sbx_abc123");
		expect(a).toBe(b);
		expect(a).toHaveLength(24);
		expect(a).toMatch(/^[0-9a-f]{24}$/);
	});

	it("returns different tokens for different sandbox ids", () => {
		const a = ttydPathToken("sbx_one");
		const b = ttydPathToken("sbx_two");
		expect(a).not.toBe(b);
	});

	it("returns different tokens for the same sandbox id under different secrets", () => {
		process.env.TTYD_TOKEN_SECRET = "secret-one";
		const a = ttydPathToken("sbx_same");
		process.env.TTYD_TOKEN_SECRET = "secret-two";
		const b = ttydPathToken("sbx_same");
		expect(a).not.toBe(b);
	});

	it("falls back to BETTER_AUTH_SECRET when TTYD_TOKEN_SECRET is unset", () => {
		unset("TTYD_TOKEN_SECRET");
		process.env.BETTER_AUTH_SECRET = "auth-secret";
		const a = ttydPathToken("sbx_x");
		// Same sandbox id with the same effective secret should be stable
		const b = ttydPathToken("sbx_x");
		expect(a).toBe(b);
		// And different from a different secret
		process.env.BETTER_AUTH_SECRET = "different-auth-secret";
		const c = ttydPathToken("sbx_x");
		expect(c).not.toBe(a);
	});

	it("uses a dev fallback when neither secret is set (warn-worthy but stable)", () => {
		unset("TTYD_TOKEN_SECRET");
		unset("BETTER_AUTH_SECRET");
		const a = ttydPathToken("sbx_y");
		const b = ttydPathToken("sbx_y");
		expect(a).toBe(b);
		expect(a).toMatch(/^[0-9a-f]{24}$/);
	});
});
