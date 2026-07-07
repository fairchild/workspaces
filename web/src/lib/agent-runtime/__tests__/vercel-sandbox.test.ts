import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
	VercelSandboxProvider,
	baseSnapshotFingerprint,
	buildGitCloneArgs,
	computeBaseSnapshotVersion,
	terminalAnthropicApiKey,
	ttydPathToken,
} from "../vercel-sandbox";

// process.env.X = undefined sets the env var to the literal string "undefined".
// Reflect.deleteProperty actually removes the key, which is what we want when
// asserting "this env var is unset". Biome's noDelete rule is overly strict
// about delete operators on dynamic properties, so we use Reflect instead.
function unset(name: string): void {
	Reflect.deleteProperty(process.env, name);
}

function restoreEnv(name: string, value: string | undefined): void {
	if (value === undefined) unset(name);
	else Reflect.set(process.env, name, value);
}

describe("ttydPathToken", () => {
	const originalSecret = process.env.TTYD_TOKEN_SECRET;
	const originalAuth = process.env.BETTER_AUTH_SECRET;
	const originalNodeEnv = process.env.NODE_ENV;

	beforeEach(() => {
		Reflect.set(process.env, "NODE_ENV", "test");
		process.env.TTYD_TOKEN_SECRET = "test-secret-fixed";
		unset("BETTER_AUTH_SECRET");
	});

	afterEach(() => {
		restoreEnv("TTYD_TOKEN_SECRET", originalSecret);
		restoreEnv("BETTER_AUTH_SECRET", originalAuth);
		restoreEnv("NODE_ENV", originalNodeEnv);
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

	it("throws in production when neither secret is set", () => {
		Reflect.set(process.env, "NODE_ENV", "production");
		unset("TTYD_TOKEN_SECRET");
		unset("BETTER_AUTH_SECRET");

		expect(() => ttydPathToken("sbx_y")).toThrow(/TTYD_TOKEN_SECRET/);
	});
});

describe("VercelSandboxProvider.checkAvailability", () => {
	const originalNodeEnv = process.env.NODE_ENV;
	const originalOidc = process.env.VERCEL_OIDC_TOKEN;
	const originalSecret = process.env.TTYD_TOKEN_SECRET;
	const originalAuth = process.env.BETTER_AUTH_SECRET;

	beforeEach(() => {
		Reflect.set(process.env, "NODE_ENV", "production");
		process.env.VERCEL_OIDC_TOKEN = "oidc-token";
		unset("TTYD_TOKEN_SECRET");
		unset("BETTER_AUTH_SECRET");
	});

	afterEach(() => {
		restoreEnv("NODE_ENV", originalNodeEnv);
		restoreEnv("VERCEL_OIDC_TOKEN", originalOidc);
		restoreEnv("TTYD_TOKEN_SECRET", originalSecret);
		restoreEnv("BETTER_AUTH_SECRET", originalAuth);
	});

	it("fails closed in production without a terminal token secret", async () => {
		const provider = new VercelSandboxProvider();

		await expect(provider.checkAvailability()).resolves.toMatchObject({
			available: false,
			reason: expect.stringContaining("TTYD_TOKEN_SECRET"),
		});
	});

	it("is available in production when BETTER_AUTH_SECRET can gate terminal URLs", async () => {
		process.env.BETTER_AUTH_SECRET = "auth-secret";
		const provider = new VercelSandboxProvider();

		await expect(provider.checkAvailability()).resolves.toEqual({
			available: true,
		});
	});
});

describe("buildGitCloneArgs", () => {
	it("uses a temporary credential helper without placing the token in argv", () => {
		const args = buildGitCloneArgs({
			cloneUrl: "https://github.com/fairchild/workspaces.git",
			authToken: "gho_secret_token",
			branch: "main",
		});

		expect(args).toEqual([
			"-c",
			expect.stringContaining("credential.helper="),
			"clone",
			"--depth",
			"1",
			"--branch",
			"main",
			"https://github.com/fairchild/workspaces.git",
			"/vercel/sandbox/repo",
		]);
		expect(args.join(" ")).not.toContain("gho_secret_token");
	});

	it("clones public URLs directly when no auth token is provided", () => {
		const args = buildGitCloneArgs({
			cloneUrl: "https://github.com/fairchild/workspaces.git",
		});

		expect(args).toEqual([
			"clone",
			"--depth",
			"1",
			"https://github.com/fairchild/workspaces.git",
			"/vercel/sandbox/repo",
		]);
	});
});

describe("terminalAnthropicApiKey", () => {
	it("does not expose the global Anthropic key to terminal sandboxes by default", () => {
		expect(
			terminalAnthropicApiKey({
				ANTHROPIC_API_KEY: "sk-test",
			}),
		).toBeNull();
	});

	it("exposes a stripped Anthropic key only with explicit terminal opt-in", () => {
		expect(
			terminalAnthropicApiKey({
				ANTHROPIC_API_KEY: '"sk-test"',
				TERMINAL_ANTHROPIC_API_KEY: "1",
			}),
		).toBe("sk-test");
	});
});

describe("base snapshot cache key", () => {
	const base = {
		miseVersion: "v2026.7.1",
		miseSha256: "a".repeat(64),
		tmuxUrl: "https://example.com/tmux.gz",
	};

	it("produces a deterministic 12-char hex fingerprint", () => {
		const a = baseSnapshotFingerprint(base);
		const b = baseSnapshotFingerprint({ ...base });
		expect(a).toBe(b);
		expect(a).toMatch(/^[0-9a-f]{12}$/);
	});

	it("changes when the mise version changes", () => {
		const before = baseSnapshotFingerprint(base);
		const after = baseSnapshotFingerprint({
			...base,
			miseVersion: "v2026.7.2",
		});
		expect(after).not.toBe(before);
	});

	it("changes when the mise checksum changes", () => {
		const before = baseSnapshotFingerprint(base);
		const after = baseSnapshotFingerprint({
			...base,
			miseSha256: "b".repeat(64),
		});
		expect(after).not.toBe(before);
	});

	it("changes when a pinned binary URL changes", () => {
		const before = baseSnapshotFingerprint(base);
		const after = baseSnapshotFingerprint({
			...base,
			tmuxUrl: "https://example.com/other.gz",
		});
		expect(after).not.toBe(before);
	});

	it("prefixes the human label and appends the fingerprint", () => {
		const version = computeBaseSnapshotVersion("v5-pi-skills", base);
		expect(version).toBe(`v5-pi-skills-${baseSnapshotFingerprint(base)}`);
		expect(version).toMatch(/^v5-pi-skills-[0-9a-f]{12}$/);
	});

	it("keeps the version stable for the same recipe (no accidental churn)", () => {
		expect(computeBaseSnapshotVersion("v5-pi-skills", base)).toBe(
			computeBaseSnapshotVersion("v5-pi-skills", { ...base }),
		);
	});
});
