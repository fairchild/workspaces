import {
	chmodSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readdirSync,
	readFileSync,
	realpathSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";
import type { StreamChunk } from "./stream-chunk";
import {
	buildClaudeArgs,
	buildHostCloneArgs,
	curatedClaudeEnv,
	HOST_ALLOWED_TOOLS,
	hostProvider,
} from "./host-provider";

let dirs: string[] = [];

function tempDir(): string {
	const dir = mkdtempSync(join(tmpdir(), "web-next-host-provider-"));
	dirs.push(dir);
	return dir;
}

afterEach(() => {
	vi.unstubAllEnvs();
	for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
	dirs = [];
});

async function collect(stream: AsyncIterable<StreamChunk>): Promise<StreamChunk[]> {
	const chunks: StreamChunk[] = [];
	for await (const chunk of stream) chunks.push(chunk);
	return chunks;
}

function workspace(root: string, sessionId: string): string {
	const dir = join(root, sessionId);
	mkdirSync(dir, { recursive: true });
	return dir;
}

function fakeClaude(script: string): string {
	return fakeExecutable("claude", script);
}

function fakeExecutable(name: string, script: string): string {
	const dir = tempDir();
	const bin = join(dir, name);
	writeFileSync(bin, script);
	chmodSync(bin, 0o755);
	return bin;
}

function readRecord(path: string): {
	argv: string[];
	env: Record<string, string | undefined>;
	cwd: string;
	stdin: string;
} {
	return JSON.parse(readFileSync(path, "utf8"));
}

function expectRestrictedLaunch(argv: string[]): void {
	expect(argv).toContain("--allowedTools");
	expect(argv[argv.indexOf("--allowedTools") + 1]).toBe(
		HOST_ALLOWED_TOOLS.join(","),
	);
	expect(argv).toContain("--tools");
	expect(argv[argv.indexOf("--tools") + 1]).toBe(HOST_ALLOWED_TOOLS.join(","));
	expect(argv).toContain("--safe-mode");
	expect(argv).toContain("--strict-mcp-config");
	expect(argv).not.toContain("--dangerously-skip-permissions");
	expect(argv).not.toContain("--allow-dangerously-skip-permissions");
	expect(HOST_ALLOWED_TOOLS).not.toContain("WebFetch");
	expect(HOST_ALLOWED_TOOLS).not.toContain("WebSearch");
	expect(argv[argv.indexOf("--allowedTools") + 1]).not.toContain("WebFetch");
	expect(argv[argv.indexOf("--allowedTools") + 1]).not.toContain("WebSearch");
	expect(argv[argv.indexOf("--tools") + 1]).not.toContain("WebFetch");
	expect(argv[argv.indexOf("--tools") + 1]).not.toContain("WebSearch");
}

async function until(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (!predicate()) {
		if (Date.now() > deadline) throw new Error("condition never held");
		await new Promise((resolve) => setTimeout(resolve, 5));
	}
}

describe("hostProvider", () => {
	test("maps local claude stream-json lines and launches with restricted curated settings", async () => {
		const root = tempDir();
		const sessionId = "session-a";
		const cwd = workspace(root, sessionId);
		const configFile = join(tempDir(), "CLAUDE.md");
		writeFileSync(configFile, "Prefer careful receipts.\n");
		const recordPath = join(tempDir(), "record.json");
		const bin = fakeClaude(`#!/usr/bin/env node
const fs = require("node:fs");
let stdin = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { stdin += chunk; });
process.stdin.on("end", () => {
  fs.writeFileSync(${JSON.stringify(recordPath)}, JSON.stringify({
    argv: process.argv.slice(2),
    env: process.env,
    cwd: process.cwd(),
    stdin,
  }));
  const events = [
    { type: "system", subtype: "init", session_id: "cli-session-1" },
    { type: "assistant", message: { content: [
      { type: "thinking", thinking: "checking" },
      { type: "text", text: "hello " },
      { type: "tool_use", id: "tool-1", name: "read", input: { file_path: "README.md" } }
    ] } },
    { type: "user", message: { content: [
      { type: "tool_result", tool_use_id: "tool-1", content: "readme body" }
    ] } },
    { type: "result", subtype: "success", session_id: "cli-session-1", duration_ms: 33, usage: {
      input_tokens: 10,
      cache_creation_input_tokens: 3,
      cache_read_input_tokens: 5,
      output_tokens: 12
    } }
  ];
  for (const event of events) console.log(JSON.stringify(event));
});
`);
		vi.stubEnv("WEB_NEXT_HOST_WORKSPACE_ROOT", root);
		vi.stubEnv("WEB_NEXT_HOST_CLAUDE_BIN", bin);
		vi.stubEnv("WEB_NEXT_CONFIG_FILES", configFile);
		vi.stubEnv("HOST_PROVIDER_SENTINEL_SECRET", "must-not-leak");
		vi.stubEnv("ANTHROPIC_API_KEY", "sk-server-side-key");

		const chunks = await collect(
			hostProvider.runTurn({
				sessionId,
				userMessage: "Inspect the readme",
				repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
				model: "claude-test-model",
			}),
		);

		expect(chunks.map((chunk) => chunk.type)).toEqual([
			"config_receipt",
			"status",
			"status",
			"reasoning",
			"text",
			"tool_use",
			"tool_result",
			"done",
		]);
		expect(chunks[0]).toMatchObject({
			type: "config_receipt",
			metadata: {
				loaded: [
					{
						path: configFile,
						basename: "CLAUDE.md",
						sha256: expect.stringMatching(/^[a-f0-9]{8}$/),
					},
				],
				skipped: [],
			},
		});
		expect(chunks[3]).toMatchObject({ content: "checking" });
		expect(chunks[5]).toMatchObject({
			type: "tool_use",
			content: "Read",
			metadata: {
				toolUseId: "tool-1",
				toolName: "Read",
				input: { file_path: "README.md" },
			},
		});
		expect(chunks[6]).toMatchObject({
			type: "tool_result",
			content: "readme body",
			metadata: { toolUseId: "tool-1", output: "readme body" },
		});
		expect(chunks.at(-1)?.metadata).toMatchObject({
			durationMs: 33,
			tokenCount: 12,
			contextTokens: 18,
			resume: {
				harnessSessionId: "cli-session-1",
				resumeState: JSON.stringify({
					provider: "host",
					sessionId: "cli-session-1",
				}),
			},
		});

		const record = readRecord(recordPath);
		expect(record.cwd).toBe(realpathSync(cwd));
		expect(record.argv).toEqual(
			expect.arrayContaining(["--model", "claude-test-model"]),
		);
		expectRestrictedLaunch(record.argv);
		const appendIndex = record.argv.indexOf("--append-system-prompt");
		expect(appendIndex).toBeGreaterThanOrEqual(0);
		expect(record.argv[appendIndex + 1]).toContain("Prefer careful receipts.");
		expect(record.argv[appendIndex + 1]).toContain(`--- BEGIN ${configFile} ---`);
		expect(record.env.HOST_PROVIDER_SENTINEL_SECRET).toBeUndefined();
		expect(record.env.WEB_NEXT_HOST_WORKSPACE_ROOT).toBeUndefined();
		// The server's API key must not reach the binary: it would silently
		// flip host turns from subscription to API-key billing (ADR).
		expect(record.env.ANTHROPIC_API_KEY).toBeUndefined();
		expect(record.stdin).toContain(
			"persistent host clone of the GitHub repository fairchild/workspaces",
		);
	});

	test("fails clearly when WEB_NEXT_HOST_WORKSPACE_ROOT is unset", async () => {
		const chunks = await collect(
			hostProvider.runTurn({
				sessionId: "session-a",
				userMessage: "go",
				repo: { fullName: "fairchild/workspaces", defaultBranch: null },
			}),
		);

		expect(chunks.map((chunk) => chunk.type)).toEqual(["error", "done"]);
		expect(chunks[0]).toMatchObject({
			metadata: { code: "host_workspace_root_unset" },
		});
		expect(chunks[1].metadata).toMatchObject({ aborted: true });
	});

	test("fails with a structured error when the claude binary is missing", async () => {
		const root = tempDir();
		workspace(root, "session-a");
		vi.stubEnv("WEB_NEXT_HOST_WORKSPACE_ROOT", root);
		vi.stubEnv("WEB_NEXT_HOST_CLAUDE_BIN", join(root, "missing-claude"));

		const chunks = await collect(
			hostProvider.runTurn({
				sessionId: "session-a",
				userMessage: "go",
				repo: { fullName: "fairchild/workspaces", defaultBranch: null },
			}),
		);

		expect(chunks.map((chunk) => chunk.type)).toEqual(["error", "done"]);
		expect(chunks[0]).toMatchObject({
			metadata: { code: "host_claude_missing" },
		});
		expect(chunks[1].metadata).toMatchObject({ aborted: true });
	});

	test("passes resume as --resume and sends only the follow-up message", async () => {
		const root = tempDir();
		const sessionId = "session-resume";
		workspace(root, sessionId);
		const recordPath = join(tempDir(), "resume-record.json");
		const bin = fakeClaude(`#!/usr/bin/env node
const fs = require("node:fs");
let stdin = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { stdin += chunk; });
process.stdin.on("end", () => {
  fs.writeFileSync(${JSON.stringify(recordPath)}, JSON.stringify({
    argv: process.argv.slice(2),
    env: process.env,
    cwd: process.cwd(),
    stdin,
  }));
  console.log(JSON.stringify({ type: "result", subtype: "success", session_id: "cli-old", duration_ms: 7 }));
});
`);
		vi.stubEnv("WEB_NEXT_HOST_WORKSPACE_ROOT", root);
		vi.stubEnv("WEB_NEXT_HOST_CLAUDE_BIN", bin);

		const chunks = await collect(
			hostProvider.runTurn({
				sessionId,
				userMessage: "Continue from here",
				repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
				resume: {
					harnessSessionId: "cli-old",
					resumeState: JSON.stringify({ provider: "host", sessionId: "cli-old" }),
				},
			}),
		);

		const record = readRecord(recordPath);
		expect(record.argv).toEqual(expect.arrayContaining(["--resume", "cli-old"]));
		expectRestrictedLaunch(record.argv);
		expect(record.stdin).toBe("Continue from here");
		expect(chunks.at(-1)?.metadata).toMatchObject({
			resume: {
				harnessSessionId: "cli-old",
				resumeState: JSON.stringify({ provider: "host", sessionId: "cli-old" }),
			},
		});
	});

	test("falls back once from a stale resume before assistant output and clears resume on double failure", async () => {
		const root = tempDir();
		const sessionId = "session-stale-resume";
		workspace(root, sessionId);
		const recordDir = tempDir();
		const countPath = join(recordDir, "count.txt");
		const bin = fakeClaude(`#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const recordDir = ${JSON.stringify(recordDir)};
const countPath = ${JSON.stringify(countPath)};
const count = fs.existsSync(countPath) ? Number(fs.readFileSync(countPath, "utf8")) : 0;
fs.writeFileSync(countPath, String(count + 1));
let stdin = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { stdin += chunk; });
process.stdin.on("end", () => {
  fs.writeFileSync(path.join(recordDir, \`attempt-\${count + 1}.json\`), JSON.stringify({
    argv: process.argv.slice(2),
    cwd: process.cwd(),
    stdin,
  }));
  console.error(count === 0 ? "stale resume failed" : "fresh fallback failed");
  process.exit(count === 0 ? 7 : 8);
});
`);
		vi.stubEnv("WEB_NEXT_HOST_WORKSPACE_ROOT", root);
		vi.stubEnv("WEB_NEXT_HOST_CLAUDE_BIN", bin);

		const chunks = await collect(
			hostProvider.runTurn({
				sessionId,
				userMessage: "Continue the analysis",
				repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
				resume: {
					harnessSessionId: "stale-cli-session",
					resumeState: JSON.stringify({
						provider: "host",
						sessionId: "stale-cli-session",
					}),
				},
				priorContext: "User: Find the issue\n\nAssistant: It is in host-provider.ts.",
			}),
		);

		expect(readFileSync(countPath, "utf8")).toBe("2");
		const first = readRecord(join(recordDir, "attempt-1.json"));
		const second = readRecord(join(recordDir, "attempt-2.json"));
		expect(first.argv).toEqual(
			expect.arrayContaining(["--resume", "stale-cli-session"]),
		);
		expectRestrictedLaunch(first.argv);
		expect(first.stdin).toBe("Continue the analysis");
		expect(second.argv).not.toContain("--resume");
		expectRestrictedLaunch(second.argv);
		expect(second.stdin).toContain(
			"The conversation so far (the local Claude session restarted",
		);
		expect(second.stdin).toContain("It is in host-provider.ts.");
		expect(second.stdin).toContain("Continue the analysis");
		expect(chunks.map((chunk) => chunk.content)).toContain(
			"Previous local Claude session failed — starting fresh",
		);
		expect(
			chunks.some((chunk) => chunk.content.includes("stale resume failed")),
		).toBe(false);
		expect(
			chunks.some((chunk) => chunk.content.includes("fresh fallback failed")),
		).toBe(true);
		expect(chunks.at(-1)).toMatchObject({
			type: "done",
			metadata: { aborted: true, resume: null },
		});
	});

	test("times out a hung turn and emits an aborted terminal chunk", async () => {
		const root = tempDir();
		const sessionId = "session-timeout";
		workspace(root, sessionId);
		const bin = fakeClaude(`#!/usr/bin/env node
process.stdin.resume();
process.stdin.on("end", () => {
  console.log(JSON.stringify({ type: "system", subtype: "init", session_id: "cli-timeout" }));
  setInterval(() => {}, 1000);
});
`);
		vi.stubEnv("WEB_NEXT_HOST_WORKSPACE_ROOT", root);
		vi.stubEnv("WEB_NEXT_HOST_CLAUDE_BIN", bin);
		vi.stubEnv("WEB_NEXT_HOST_TURN_TIMEOUT_MS", "300");

		const chunks = await collect(
			hostProvider.runTurn({
				sessionId,
				userMessage: "wait forever",
				repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
			}),
		);

		expect(chunks.slice(-2)).toMatchObject([
			{
				type: "error",
				metadata: { code: "host_turn_timeout" },
			},
			{ type: "done", metadata: { aborted: true } },
		]);
	});

	test("kills the claude process group so descendants do not survive timeout", async () => {
		const root = tempDir();
		const sessionId = "session-group-kill";
		workspace(root, sessionId);
		const sentinel = join(tempDir(), "grandchild-survived.txt");
		const bin = fakeClaude(`#!/usr/bin/env node
const { spawn } = require("node:child_process");
process.stdin.resume();
process.stdin.on("end", () => {
  spawn(process.execPath, [
    "-e",
    "setTimeout(() => require('node:fs').writeFileSync(${JSON.stringify(sentinel)}, 'alive'), 250)"
  ], { stdio: "ignore" });
  setInterval(() => {}, 1000);
});
`);
		vi.stubEnv("WEB_NEXT_HOST_WORKSPACE_ROOT", root);
		vi.stubEnv("WEB_NEXT_HOST_CLAUDE_BIN", bin);
		vi.stubEnv("WEB_NEXT_HOST_TURN_TIMEOUT_MS", "300");

		const chunks = await collect(
			hostProvider.runTurn({
				sessionId,
				userMessage: "wait with a descendant",
				repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
			}),
		);
		await new Promise((resolve) => setTimeout(resolve, 400));

		expect(chunks.at(-1)).toMatchObject({
			type: "done",
			metadata: { aborted: true },
		});
		expect(existsSync(sentinel)).toBe(false);
	});

	test("caps retained stderr to the last 8 KiB", async () => {
		const root = tempDir();
		const sessionId = "session-stderr-cap";
		workspace(root, sessionId);
		const bin = fakeClaude(`#!/usr/bin/env node
process.stdin.resume();
process.stdin.on("end", () => {
  process.stderr.write("HEAD-MARKER" + "A".repeat(12000) + "TAIL-MARKER");
  process.exit(9);
});
`);
		vi.stubEnv("WEB_NEXT_HOST_WORKSPACE_ROOT", root);
		vi.stubEnv("WEB_NEXT_HOST_CLAUDE_BIN", bin);

		const chunks = await collect(
			hostProvider.runTurn({
				sessionId,
				userMessage: "fail loudly",
				repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
			}),
		);

		const error = chunks.find((chunk) => chunk.type === "error")?.content ?? "";
		expect(error).toContain("stderr truncated to last 8192 bytes");
		expect(error).toContain("TAIL-MARKER");
		expect(error).not.toContain("HEAD-MARKER");
		expect(error.length).toBeLessThan(8_700);
		expect(chunks.at(-1)).toMatchObject({
			type: "done",
			metadata: { aborted: true },
		});
	});

	test("serializes same-session workspace setup so concurrent first turns clone once", async () => {
		const root = tempDir();
		const sessionId = "session-clone-race";
		const recordDir = tempDir();
		const cloneCount = join(recordDir, "clone-count.txt");
		const git = fakeExecutable("git", `#!/usr/bin/env node
const fs = require("node:fs");
const target = process.argv[process.argv.length - 1];
const countPath = ${JSON.stringify(cloneCount)};
const count = fs.existsSync(countPath) ? Number(fs.readFileSync(countPath, "utf8")) : 0;
fs.writeFileSync(countPath, String(count + 1));
setTimeout(() => {
  fs.mkdirSync(target, { recursive: true });
  process.exit(0);
}, 100);
`);
		const bin = fakeClaude(`#!/usr/bin/env node
process.stdin.resume();
process.stdin.on("end", () => {
  console.log(JSON.stringify({ type: "result", subtype: "success", session_id: "cli-race", duration_ms: 1 }));
});
`);
		vi.stubEnv("PATH", `${dirname(git)}:${process.env.PATH ?? ""}`);
		vi.stubEnv("WEB_NEXT_HOST_WORKSPACE_ROOT", root);
		vi.stubEnv("WEB_NEXT_HOST_CLAUDE_BIN", bin);

		await Promise.all([
			collect(
				hostProvider.runTurn({
					sessionId,
					userMessage: "first",
					repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
				}),
			),
			collect(
				hostProvider.runTurn({
					sessionId,
					userMessage: "second",
					repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
				}),
			),
		]);

		expect(readFileSync(cloneCount, "utf8")).toBe("1");
		expect(readdirSync(join(root, sessionId))).toEqual([]);
	});

	test("aborts the child with SIGTERM and closes the stream", async () => {
		const root = tempDir();
		const sessionId = "session-abort";
		workspace(root, sessionId);
		const recordPath = join(tempDir(), "abort-record.json");
		const signalPath = join(tempDir(), "signal.txt");
		const bin = fakeClaude(`#!/usr/bin/env node
const fs = require("node:fs");
process.on("SIGTERM", () => {
  fs.writeFileSync(${JSON.stringify(signalPath)}, "SIGTERM");
  process.exit(0);
});
let stdin = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { stdin += chunk; });
process.stdin.on("end", () => {
  fs.writeFileSync(${JSON.stringify(recordPath)}, JSON.stringify({
    argv: process.argv.slice(2),
    env: process.env,
    cwd: process.cwd(),
    stdin,
  }));
  console.log(JSON.stringify({ type: "system", subtype: "init", session_id: "cli-abort" }));
  setInterval(() => {}, 1000);
});
`);
		vi.stubEnv("WEB_NEXT_HOST_WORKSPACE_ROOT", root);
		vi.stubEnv("WEB_NEXT_HOST_CLAUDE_BIN", bin);
		const controller = new AbortController();

		const pending = collect(
			hostProvider.runTurn({
				sessionId,
				userMessage: "wait",
				repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
				signal: controller.signal,
			}),
		);
		await until(() => existsSync(recordPath));
		controller.abort();
		const chunks = await pending;

		expect(readFileSync(signalPath, "utf8")).toBe("SIGTERM");
		expectRestrictedLaunch(readRecord(recordPath).argv);
		expect(chunks.slice(-2)).toMatchObject([
			{ type: "error", content: "Turn stopped." },
			{ type: "done", metadata: { aborted: true } },
		]);
	});
});

describe("host provider helpers", () => {
	test("API-key env reaches the child only on explicit opt-in (billing guard)", () => {
		const source: NodeJS.ProcessEnv = {
			NODE_ENV: "test",
			HOME: "/Users/owner",
			ANTHROPIC_API_KEY: "sk-server",
			ANTHROPIC_AUTH_TOKEN: "tok-server",
			CLAUDE_CODE_OAUTH_TOKEN: "subscription-ci-token",
		};
		const defaults = curatedClaudeEnv(source);
		expect(defaults.ANTHROPIC_API_KEY).toBeUndefined();
		expect(defaults.ANTHROPIC_AUTH_TOKEN).toBeUndefined();
		// The subscription paths stay available without opt-in.
		expect(defaults.CLAUDE_CODE_OAUTH_TOKEN).toBe("subscription-ci-token");
		expect(defaults.HOME).toBe("/Users/owner");

		const optedIn = curatedClaudeEnv({
			...source,
			WEB_NEXT_HOST_PASS_API_KEY: "1",
		});
		expect(optedIn.ANTHROPIC_API_KEY).toBe("sk-server");
		expect(optedIn.ANTHROPIC_AUTH_TOKEN).toBe("tok-server");
	});

	test("builds shallow clone args with the session repo default branch", () => {
		expect(
			buildHostCloneArgs(
				{ fullName: "fairchild/workspaces", defaultBranch: "trunk" },
				"/tmp/s1",
			),
		).toEqual([
			"clone",
			"--depth",
			"50",
			"--branch",
			"trunk",
			"https://github.com/fairchild/workspaces.git",
			"/tmp/s1",
		]);
		expect(
			buildHostCloneArgs(
				{ fullName: "fairchild/workspaces", defaultBranch: null },
				"/tmp/s1",
			),
		).toEqual([
			"clone",
			"--depth",
			"50",
			"https://github.com/fairchild/workspaces.git",
			"/tmp/s1",
		]);
	});

	test("always includes read-only tool restriction flags and never skip-permissions flags", () => {
		const freshArgs = buildClaudeArgs({ model: "claude-test" });
		const resumeArgs = buildClaudeArgs({
			resume: { harnessSessionId: "cli-1", resumeState: "{}" },
		});

		expectRestrictedLaunch(freshArgs);
		expectRestrictedLaunch(resumeArgs);
		expect(resumeArgs).toEqual(expect.arrayContaining(["--resume", "cli-1"]));
	});
});
