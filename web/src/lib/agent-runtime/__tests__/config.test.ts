import { describe, expect, it } from "vitest";
import {
	parseAllowedAgentLogins,
	resolveBetterAuthSecret,
	shouldExposeAnthropicKeyToTerminal,
	validateProductionAgentRuntimeConfig,
	validateProductionAuthConfig,
} from "../config";

describe("agent runtime config", () => {
	it("does not apply the development allowlist default in production", () => {
		const logins = parseAllowedAgentLogins({ NODE_ENV: "production" });

		expect(logins.size).toBe(0);
		expect(logins.has("fairchild")).toBe(false);
	});

	it("keeps the development allowlist default outside production", () => {
		const logins = parseAllowedAgentLogins({ NODE_ENV: "test" });

		expect(logins.has("fairchild")).toBe(true);
	});

	it("fails closed in production when security-critical config is missing", () => {
		expect(() =>
			validateProductionAgentRuntimeConfig({ NODE_ENV: "production" }),
		).toThrow(
			/ALLOWED_AGENT_LOGINS[\s\S]*BETTER_AUTH_SECRET[\s\S]*TTYD_TOKEN_SECRET[\s\S]*Vercel Sandbox credentials[\s\S]*ANTHROPIC_API_KEY/,
		);
	});

	it("accepts complete production runtime config", () => {
		expect(() =>
			validateProductionAgentRuntimeConfig({
				NODE_ENV: "production",
				ALLOWED_AGENT_LOGINS: "fairchild,octocat",
				BETTER_AUTH_SECRET: "auth-secret",
				TTYD_TOKEN_SECRET: "ttyd-secret",
				VERCEL_OIDC_TOKEN: "oidc-token",
				ANTHROPIC_API_KEY: "sk-test",
			}),
		).not.toThrow();
	});

	it("requires GitHub App credentials when the PR reviewer is enabled", () => {
		expect(() =>
			validateProductionAgentRuntimeConfig({
				NODE_ENV: "production",
				ALLOWED_AGENT_LOGINS: "fairchild",
				BETTER_AUTH_SECRET: "auth-secret",
				TTYD_TOKEN_SECRET: "ttyd-secret",
				VERCEL_OIDC_TOKEN: "oidc-token",
				ANTHROPIC_API_KEY: "sk-test",
				PR_REVIEWER_ENABLED: "1",
			}),
		).toThrow(
			/PR_REVIEWER_APP_ID[\s\S]*PR_REVIEWER_PRIVATE_KEY[\s\S]*PR_REVIEWER_INSTALLATION_ID/,
		);
	});

	it("requires Better Auth secret in production auth config", () => {
		expect(() =>
			validateProductionAuthConfig({ NODE_ENV: "production" }),
		).toThrow(/BETTER_AUTH_SECRET/);
	});

	it("does not fail preview builds like production runtime", () => {
		expect(() =>
			validateProductionAuthConfig({
				NODE_ENV: "production",
				VERCEL_ENV: "preview",
			}),
		).not.toThrow();
		expect(() =>
			validateProductionAgentRuntimeConfig({
				NODE_ENV: "production",
				VERCEL_ENV: "preview",
			}),
		).not.toThrow();
		expect(
			resolveBetterAuthSecret({
				NODE_ENV: "production",
				VERCEL_ENV: "preview",
			}),
		).toBeTruthy();
	});

	it("does not allow an implicit auth secret in production", () => {
		expect(() => resolveBetterAuthSecret({ NODE_ENV: "production" })).toThrow(
			/BETTER_AUTH_SECRET/,
		);
	});

	it("does not expose Anthropic keys to terminal sandboxes without explicit opt-in", () => {
		expect(
			shouldExposeAnthropicKeyToTerminal({
				ANTHROPIC_API_KEY: "sk-test",
			}),
		).toBe(false);

		expect(
			shouldExposeAnthropicKeyToTerminal({
				ANTHROPIC_API_KEY: "sk-test",
				TERMINAL_ANTHROPIC_API_KEY: "1",
			}),
		).toBe(true);
	});
});
