import {
	chmodSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	realpathSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";
import type { StreamChunk } from "./stream-chunk";
import {
	buildClaudeArgs,
	buildHostCloneArgs,
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
	const dir = tempDir();
	const bin = join(dir, "claude");
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
	expect(argv).not.toContain("--dangerously-skip-permissions");
	expect(argv).not.toContain("--allow-dangerously-skip-permissions");
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
		vi.stubEnv("HOST_PROVIDER_SENTINEL_SECRET", "must-not-leak");

		const chunks = await collect(
			hostProvider.runTurn({
				sessionId,
				userMessage: "Inspect the readme",
				repo: { fullName: "fairchild/workspaces", defaultBranch: "main" },
				model: "claude-test-model",
			}),
		);

		expect(chunks.map((chunk) => chunk.type)).toEqual([
			"status",
			"status",
			"reasoning",
			"text",
			"tool_use",
			"tool_result",
			"done",
		]);
		expect(chunks[2]).toMatchObject({ content: "checking" });
		expect(chunks[4]).toMatchObject({
			type: "tool_use",
			content: "Read",
			metadata: {
				toolUseId: "tool-1",
				toolName: "Read",
				input: { file_path: "README.md" },
			},
		});
		expect(chunks[5]).toMatchObject({
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
		expect(record.env.HOST_PROVIDER_SENTINEL_SECRET).toBeUndefined();
		expect(record.env.WEB_NEXT_HOST_WORKSPACE_ROOT).toBeUndefined();
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
