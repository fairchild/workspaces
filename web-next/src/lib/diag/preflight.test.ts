import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { runPreflight } from "./preflight";

const tempRoots: string[] = [];

function tempRoot(): string {
	const root = mkdtempSync(join(tmpdir(), "web-next-preflight-"));
	tempRoots.push(root);
	return root;
}

afterEach(() => {
	for (const root of tempRoots.splice(0)) {
		rmSync(root, { recursive: true, force: true });
	}
});

const hostDependencies = {
	resolveClaude: async () => "/opt/bin/claude",
	version: async (command: string) =>
		command === "git" ? "git version 2.50.0" : "2.1.206 (Claude Code)",
};

describe("provider-aware preflight", () => {
	test("host gates only Claude, git, and its writable workspace root", async () => {
		const report = await runPreflight({
			includeSandbox: true,
			provider: "host",
			env: {
				NODE_ENV: "test",
				PATH: "/usr/bin:/bin",
				WEB_NEXT_HOST_WORKSPACE_ROOT: join(tempRoot(), "sessions"),
				// An inactive provider's stale credential must not fail this report.
				VERCEL_TOKEN: "expired-token",
			},
			hostDependencies,
		});

		expect(report).toMatchObject({ ok: true, provider: "host" });
		expect(
			report.checks
				.filter((check) => ["env", "llm", "vercel", "github", "sandbox"].includes(check.name))
				.every((check) => check.ok && check.skipped),
		).toBe(true);
		expect(
			report.checks
				.filter((check) => check.name.startsWith("host:"))
				.map((check) => [check.name, check.ok]),
		).toEqual([
			["host:claude", true],
			["host:git", true],
			["host:workspace", true],
		]);
	});

	test("host fails when its workspace root is not configured", async () => {
		const report = await runPreflight({
			includeSandbox: false,
			provider: "host",
			env: { NODE_ENV: "test", PATH: "/usr/bin:/bin" },
			hostDependencies,
		});

		expect(report.ok).toBe(false);
		expect(report.checks.find((check) => check.name === "host:workspace")).toMatchObject({
			ok: false,
			error: "WEB_NEXT_HOST_WORKSPACE_ROOT unset",
		});
	});

	test("mock fails closed because it is not a real runtime", async () => {
		const report = await runPreflight({
			includeSandbox: false,
			env: { NODE_ENV: "test" },
		});

		expect(report).toMatchObject({ ok: false, provider: "mock" });
		expect(report.checks).toEqual([
			expect.objectContaining({
				name: "provider",
				ok: false,
				error: "mock is not a configured real compute provider",
			}),
		]);
	});

	test("derives the active provider through the runtime's selection function", async () => {
		const report = await runPreflight({
			includeSandbox: false,
			env: {
				NODE_ENV: "test",
				PATH: "/usr/bin:/bin",
				WEB_NEXT_COMPUTE_PROVIDER: "host",
				WEB_NEXT_HOST_WORKSPACE_ROOT: join(tempRoot(), "sessions"),
			},
			hostDependencies,
		});

		expect(report).toMatchObject({ ok: true, provider: "host" });
	});
});
