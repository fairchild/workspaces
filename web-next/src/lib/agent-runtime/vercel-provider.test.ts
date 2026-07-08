import { describe, expect, test } from "vitest";
import { projectReplayContext } from "../transcript/replay-context";
import {
	buildPrompt,
	buildSessionSetupScript,
	canonicalToolName,
	checkpointSessionBranch,
	createHarness,
	errorText,
	mapFullStream,
	parseGitDiff,
	resolveTargetRepo,
	runTurnTail,
	toolResultContent,
	uniqueDiffToolCallId,
	vercelProvider,
	WORKSPACE_DIR,
} from "./vercel-provider";
import type { StreamChunk } from "./stream-chunk";
import type { RunnableSandbox } from "./vercel-provider";

type Part = { type: string; [k: string]: unknown };
type RunResult = { exitCode: number; stdout: string; stderr: string };

function runResult(
	stdout = "",
	exitCode = 0,
	stderr = "",
): RunResult {
	return { exitCode, stdout, stderr };
}

class RecordingSandbox implements RunnableSandbox {
	readonly calls: string[] = [];

	constructor(private readonly respond: (command: string) => RunResult) {}

	async run({ command }: { command: string }): Promise<RunResult> {
		this.calls.push(command);
		return this.respond(command);
	}
}

async function collect(parts: Part[]): Promise<StreamChunk[]> {
	async function* source(): AsyncIterable<Part> {
		for (const part of parts) yield part;
	}
	const out: StreamChunk[] = [];
	for await (const chunk of mapFullStream(source(), 0)) out.push(chunk);
	return out;
}

async function collectTail(
	sandbox: RunnableSandbox,
	events: string[],
): Promise<{ chunks: StreamChunk[]; detached: boolean }> {
	const chunks: StreamChunk[] = [];
	const tail = runTurnTail({
		sandbox,
		branch: "agent/session-abcdef12",
		seenToolCallIds: new Set(),
		doneChunk: { type: "done", content: "", metadata: { tokenCount: 7 } },
		session: {
			detach: async () => {
				events.push("detach");
				return { parked: true };
			},
		},
		sandboxSessionId: "sandbox-1",
		debug: false,
	});

	for (;;) {
		const next = await tail.next();
		if (next.done) return { chunks, detached: next.value };
		chunks.push(next.value);
	}
}

describe("repo targeting", () => {
	test("resolves the repo carried on the turn request", () => {
		expect(
			resolveTargetRepo({
				repo: {
					fullName: "fairchild/web-next-fixtures",
					defaultBranch: "trunk",
				},
			}),
		).toEqual({
			ok: true,
			repo: {
				fullName: "fairchild/web-next-fixtures",
				defaultBranch: "trunk",
			},
		});
	});

	test("builds setup and first-turn prompt from the request repo", () => {
		const repo = {
			fullName: "fairchild/web-next-fixtures",
			defaultBranch: "trunk",
		};

		const script = buildSessionSetupScript("abcdef123456", repo);
		expect(script).toContain(
			"git clone --depth 50 --branch \"$DEFAULT_BRANCH\" https://github.com/fairchild/web-next-fixtures.git",
		);
		expect(script).toContain(
			'printf "%s" "$DEFAULT_BRANCH" > /tmp/default_branch',
		);

		const prompt = buildPrompt("Fix the failing test", "abcdef123456", true, repo);
		expect(prompt).toContain(
			"persistent clone of the GitHub repository fairchild/web-next-fixtures",
		);
		expect(prompt).toContain(
			"https://api.github.com/repos/fairchild/web-next-fixtures/pulls",
		);
		expect(prompt).toContain("BASE_BRANCH='trunk'");
		expect(prompt).toContain('\\"base\\":\\"$BASE_BRANCH\\"');
		expect(prompt).not.toContain("fairchild/workspaces");
		expect(prompt).not.toContain('"base":"main"');
	});

	test("uses the clone default HEAD fallback when the repo row has no default branch", () => {
		const repo = {
			fullName: "fairchild/web-next-fixtures",
			defaultBranch: null,
		};

		const script = buildSessionSetupScript("abcdef123456", repo);
		expect(script).toContain(
			"git clone --depth 50 https://github.com/fairchild/web-next-fixtures.git",
		);
		expect(script).toContain("symbolic-ref --quiet --short refs/remotes/origin/HEAD");

		const prompt = buildPrompt("Fix the failing test", "abcdef123456", true, repo);
		expect(prompt).toContain("the clone's default HEAD");
		expect(prompt).toContain('BASE_BRANCH="$(cat /tmp/default_branch)"');
	});

	test("rejects invalid repo full names with structured chunks before setup", async () => {
		const chunks: StreamChunk[] = [];
		for await (const chunk of vercelProvider.runTurn({
			sessionId: "s-bad-repo",
			userMessage: "go",
			repo: {
				fullName: "fairchild/workspaces;rm -rf /",
				defaultBranch: null,
			},
		})) {
			chunks.push(chunk);
		}

		expect(chunks.map((chunk) => chunk.type)).toEqual(["error", "done"]);
		expect(chunks[0]).toMatchObject({
			type: "error",
			content:
				'invalid repository full name for agent runtime: "fairchild/workspaces;rm -rf /"',
			metadata: { code: "invalid_repo" },
		});
		expect(chunks[1]).toMatchObject({
			type: "done",
			metadata: { aborted: true },
		});
	});
});

describe("buildPrompt", () => {
	const repo = {
		fullName: "fairchild/web-next-fixtures",
		defaultBranch: "trunk",
	};

	test("frames projected prior context on a fresh fallback with history", () => {
		const priorContext = projectReplayContext([
			{ seq: 1, role: "user", chunk: { type: "text", content: "Fix resume" } },
			{
				seq: 2,
				role: "assistant",
				chunk: { type: "text", content: "I restored the branch." },
			},
			{ seq: 3, role: "assistant", chunk: { type: "done", content: "" } },
		]);

		const prompt = buildPrompt(
			"Now add the replay test",
			"abcdef123456",
			true,
			repo,
			priorContext,
		);

		expect(prompt).toContain(
			"The conversation so far (the sandbox restarted; your working copy was restored from the session branch):",
		);
		expect(prompt).toContain("User: Fix resume");
		expect(prompt).toContain("Assistant: I restored the branch.");
		expect(prompt.indexOf("User: Fix resume")).toBeLessThan(
			prompt.indexOf("The user's request:"),
		);
		expect(prompt).toContain("The user's request:\nNow add the replay test");
	});

	test("keeps the first-turn prompt byte-identical when no prior context exists", () => {
		const prompt = buildPrompt("Fix the failing test", "abcdef123456", true, repo);

		expect(buildPrompt("Fix the failing test", "abcdef123456", true, repo, null)).toBe(
			prompt,
		);
		expect(
			buildPrompt("Fix the failing test", "abcdef123456", true, repo, " \n\t "),
		).toBe(prompt);
		expect(prompt).not.toContain("The conversation so far");
	});

	test("ignores priorContext on a successful warm resume", () => {
		expect(
			buildPrompt(
				"Continue from the live harness session",
				"abcdef123456",
				false,
				repo,
				"User: old\n\nAssistant: context",
			),
		).toBe("Continue from the live harness session");
	});
});

describe("mapFullStream", () => {
	test("maps deltas and tool parts onto StreamChunks", async () => {
		const chunks = await collect([
			{ type: "start" }, // structural — dropped
			{ type: "reasoning-delta", id: "r1", text: "thinking" },
			{ type: "text-delta", id: "t1", text: "hello " },
			{ type: "text-delta", id: "t1", text: "world" },
			{
				type: "tool-call",
				toolCallId: "c1",
				toolName: "bash",
				input: { command: "ls" },
			},
			{ type: "tool-result", toolCallId: "c1", toolName: "bash", output: "a\nb" },
			{
				type: "finish",
				finishReason: "stop",
				totalUsage: { outputTokens: { total: 42 }, inputTokens: { total: 100 } },
			},
		]);

		expect(chunks.map((c) => c.type)).toEqual([
			"reasoning",
			"text",
			"text",
			"tool_use",
			"tool_result",
			"done",
		]);

		// Tool names are canonicalized to the Capitalized form Folio keys on.
		const toolUse = chunks.find((c) => c.type === "tool_use");
		expect(toolUse?.content).toBe("Bash");
		expect(toolUse?.metadata).toMatchObject({
			toolUseId: "c1",
			toolName: "Bash",
			input: { command: "ls" },
		});

		const toolResult = chunks.find((c) => c.type === "tool_result");
		expect(toolResult?.content).toBe("a\nb");
		expect(toolResult?.metadata).toMatchObject({ toolUseId: "c1" });
	});

	test("extracts stdout from a bash-style object tool result", async () => {
		const chunks = await collect([
			{
				type: "tool-result",
				toolCallId: "c9",
				toolName: "bash",
				output: { exitCode: 0, stdout: "12 passed\n", stderr: "" },
			},
		]);
		const result = chunks.find((c) => c.type === "tool_result");
		expect(result?.content).toBe("12 passed");
		expect(result?.metadata).toMatchObject({ toolUseId: "c9", output: "12 passed" });
	});

	test("carries finish outputTokens into the terminal done chunk", async () => {
		const chunks = await collect([
			{ type: "text-delta", id: "t1", text: "hi" },
			{
				type: "finish",
				finishReason: "stop",
				totalUsage: { outputTokens: { total: 7 } },
			},
		]);
		const done = chunks.at(-1);
		expect(done?.type).toBe("done");
		expect(done?.metadata).toMatchObject({ tokenCount: 7 });
		expect(typeof done?.metadata?.durationMs).toBe("number");
	});

	test("carries finish inputTokens into the terminal done chunk as contextTokens (#824)", async () => {
		const chunks = await collect([
			{ type: "text-delta", id: "t1", text: "hi" },
			{
				type: "finish",
				finishReason: "stop",
				totalUsage: {
					outputTokens: { total: 7 },
					inputTokens: { total: 1234 },
				},
			},
		]);
		const done = chunks.at(-1);
		expect(done?.metadata).toMatchObject({ tokenCount: 7, contextTokens: 1234 });
	});

	test("tool-error maps to an errored tool_result", async () => {
		const chunks = await collect([
			{ type: "tool-error", toolCallId: "c1", error: "boom" },
		]);
		const result = chunks.find((c) => c.type === "tool_result");
		expect(result?.content).toBe("boom");
		expect(result?.metadata).toMatchObject({ toolUseId: "c1", isError: true });
	});

	test("error and abort parts both surface as error chunks", async () => {
		const errChunks = await collect([{ type: "error", error: "kaput" }]);
		expect(errChunks[0]).toMatchObject({ type: "error", content: "kaput" });

		const abortChunks = await collect([{ type: "abort", reason: "cancelled" }]);
		expect(abortChunks[0]).toMatchObject({
			type: "error",
			content: "aborted: cancelled",
		});
	});

	test("always ends with exactly one done chunk, even with no finish part", async () => {
		const chunks = await collect([{ type: "text-delta", id: "t1", text: "x" }]);
		const dones = chunks.filter((c) => c.type === "done");
		expect(dones).toHaveLength(1);
		expect(chunks.at(-1)?.type).toBe("done");
		expect(dones[0]?.metadata?.tokenCount).toBeUndefined();
	});
});

describe("createHarness", () => {
	test("forwards the session's model override into createClaudeCode settings (#824)", () => {
		const calls: unknown[] = [];
		const fakeCreateClaudeCode = ((settings: unknown) => {
			calls.push(settings);
			return {};
			// biome-ignore-like cast: only the settings arg matters to this test.
		}) as unknown as Parameters<typeof createHarness>[0];

		createHarness(fakeCreateClaudeCode, undefined, "claude-opus-4-8");
		expect(calls[0]).toMatchObject({ thinking: "on", model: "claude-opus-4-8" });
	});

	test("omits model entirely when none is given, deferring to the CLI default", () => {
		const calls: unknown[] = [];
		const fakeCreateClaudeCode = ((settings: unknown) => {
			calls.push(settings);
			return {};
		}) as unknown as Parameters<typeof createHarness>[0];

		createHarness(fakeCreateClaudeCode, undefined);
		expect(calls[0]).not.toHaveProperty("model");
	});
});

describe("buildSessionSetupScript", () => {
	test("checks out an existing remote session branch on a fresh clone (#968)", () => {
		const script = buildSessionSetupScript("abcdef1234567890", {
			fullName: "fairchild/web-next-fixtures",
			defaultBranch: "trunk",
		});

		expect(script).toContain(
			`git clone --depth 50 --branch "$DEFAULT_BRANCH" https://github.com/fairchild/web-next-fixtures.git ${WORKSPACE_DIR}`,
		);
		expect(script).toContain(
			`git -C ${WORKSPACE_DIR} ls-remote --exit-code --heads origin 'agent/session-abcdef12'`,
		);
		expect(script).toContain(
			`git -C ${WORKSPACE_DIR} fetch --depth 50 origin 'refs/heads/agent/session-abcdef12:refs/remotes/origin/agent/session-abcdef12'`,
		);
		expect(script).toContain(
			`git -C ${WORKSPACE_DIR} checkout 'agent/session-abcdef12'`,
		);
		expect(script).toContain(
			`git -C ${WORKSPACE_DIR} checkout -b 'agent/session-abcdef12'`,
		);
		expect(script).not.toContain("fairchild/workspaces.git");
	});
});

describe("checkpointSessionBranch", () => {
	test("skips add, commit, and push when tree and remote branch are already clean", async () => {
		const events: string[] = [];
		const sandbox = new RecordingSandbox((command) => {
			if (command.includes("status --porcelain")) {
				events.push("status");
				return runResult("");
			}
			if (command.includes("ls-remote --exit-code")) {
				events.push("ls-remote");
				return runResult("");
			}
			if (command.includes("fetch --depth 50")) {
				events.push("fetch");
				return runResult("");
			}
			if (command.includes("rev-list --count")) {
				events.push("ahead");
				return runResult("0\n");
			}
			throw new Error(`unexpected command: ${command}`);
		});

		const status = await checkpointSessionBranch(
			sandbox,
			"agent/session-abcdef12",
		);

		expect(status).toBeUndefined();
		expect(events).toEqual(["status", "ls-remote", "fetch", "ahead"]);
		expect(sandbox.calls.some((c) => c.includes(" add -A"))).toBe(false);
		expect(sandbox.calls.some((c) => c.includes(" commit -m "))).toBe(false);
		expect(sandbox.calls.some((c) => c.includes(" push -u origin "))).toBe(false);
	});
});

describe("runTurnTail", () => {
	test("emits Diff rows, then pushes a checkpoint, then parks", async () => {
		const events: string[] = [];
		const sandbox = new RecordingSandbox((command) => {
			if (command.includes("add -N .") && command.includes(" diff")) {
				events.push("diff");
				return runResult(
					[
						"diff --git a/web-next/src/demo.ts b/web-next/src/demo.ts",
						"--- a/web-next/src/demo.ts",
						"+++ b/web-next/src/demo.ts",
						"@@ -1 +1 @@",
						"-old",
						"+new",
					].join("\n"),
				);
			}
			if (command.includes("status --porcelain")) {
				events.push("status");
				return runResult(" M web-next/src/demo.ts\n");
			}
			if (command.includes(" add -A")) {
				events.push("add");
				return runResult("");
			}
			if (command.includes("diff --cached --quiet")) {
				events.push("staged");
				return runResult("dirty");
			}
			if (command.includes(" commit -m ")) {
				events.push("commit");
				return runResult("[agent/session-abcdef12 1234567] checkpoint\n");
			}
			if (command.includes("ls-remote --exit-code")) {
				events.push("ls-remote");
				return runResult("");
			}
			if (command.includes("fetch --depth 50")) {
				events.push("fetch");
				return runResult("");
			}
			if (command.includes("rev-list --count")) {
				events.push("ahead");
				return runResult("1\n");
			}
			if (command.includes(" push -u origin ")) {
				events.push("push");
				expect(command).toContain("push -u origin 'agent/session-abcdef12'");
				return runResult("branch pushed\n");
			}
			throw new Error(`unexpected command: ${command}`);
		});

		const { chunks, detached } = await collectTail(sandbox, events);

		expect(detached).toBe(true);
		expect(events).toEqual([
			"diff",
			"status",
			"add",
			"staged",
			"commit",
			"ls-remote",
			"fetch",
			"ahead",
			"push",
			"detach",
		]);
		expect(chunks.map((c) => c.type)).toEqual([
			"tool_use",
			"tool_result",
			"status",
			"done",
		]);
		expect(chunks[2]).toMatchObject({
			type: "status",
			content: "Pushed checkpoint to agent/session-abcdef12",
		});
		expect(chunks.at(-1)?.metadata).toMatchObject({
			tokenCount: 7,
			resume: {
				harnessSessionId: "sandbox-1",
				resumeState: JSON.stringify({ parked: true }),
			},
		});
	});

	test("push failure yields a calm status and still parks the turn", async () => {
		const events: string[] = [];
		const sandbox = new RecordingSandbox((command) => {
			if (command.includes("add -N .") && command.includes(" diff")) {
				events.push("diff");
				return runResult("");
			}
			if (command.includes("status --porcelain")) {
				events.push("status");
				return runResult(" M web-next/src/demo.ts\n");
			}
			if (command.includes(" add -A")) {
				events.push("add");
				return runResult("");
			}
			if (command.includes("diff --cached --quiet")) {
				events.push("staged");
				return runResult("dirty");
			}
			if (command.includes(" commit -m ")) {
				events.push("commit");
				return runResult("[agent/session-abcdef12 1234567] checkpoint\n");
			}
			if (command.includes("ls-remote --exit-code")) {
				events.push("ls-remote");
				return runResult("", 2);
			}
			if (command.includes("rev-list --count")) {
				events.push("ahead");
				return runResult("1\n");
			}
			if (command.includes(" push -u origin ")) {
				events.push("push");
				return runResult("", 1, "remote rejected checkpoint");
			}
			throw new Error(`unexpected command: ${command}`);
		});

		const { chunks, detached } = await collectTail(sandbox, events);

		expect(detached).toBe(true);
		expect(events).toEqual([
			"diff",
			"status",
			"add",
			"staged",
			"commit",
			"ls-remote",
			"ahead",
			"push",
			"detach",
		]);
		expect(chunks.map((c) => c.type)).toEqual(["status", "done"]);
		expect(chunks[0]).toMatchObject({
			type: "status",
			content:
				"Checkpoint push failed: checkpoint push failed (exit 1): remote rejected checkpoint",
		});
		expect(chunks.some((c) => c.type === "error")).toBe(false);
	});
});

describe("errorText", () => {
	test("reads .message from an Error, which JSON.stringify hides as {}", () => {
		expect(errorText(new Error("bufferUtil.mask is not a function"))).toBe(
			"bufferUtil.mask is not a function",
		);
		expect(JSON.stringify(new Error("x"))).toBe("{}"); // the trap this avoids
	});
	test("unwraps common nested error shapes", () => {
		expect(errorText({ message: "top" })).toBe("top");
		expect(errorText({ error: { message: "nested" } })).toBe("nested");
		expect(errorText({ cause: new Error("caused") })).toBe("caused");
	});
	test("falls back for strings, empties, and null", () => {
		expect(errorText("plain")).toBe("plain");
		expect(errorText(null)).toBe("unknown error");
		expect(errorText({})).toBe("[object Object]");
	});
});

describe("canonicalToolName", () => {
	test("capitalizes the harness's lowercase tool names", () => {
		expect(canonicalToolName("write")).toBe("Write");
		expect(canonicalToolName("edit")).toBe("Edit");
		expect(canonicalToolName("bash")).toBe("Bash");
		expect(canonicalToolName("read")).toBe("Read");
	});
	test("leaves already-capitalized and empty names alone", () => {
		expect(canonicalToolName("Grep")).toBe("Grep");
		expect(canonicalToolName("")).toBe("");
	});
});

describe("toolResultContent", () => {
	test("surfaces stdout/stderr from a command result object", () => {
		expect(toolResultContent({ exitCode: 0, stdout: "ok\n", stderr: "" })).toBe("ok");
		expect(toolResultContent({ exitCode: 1, stdout: "", stderr: "boom\n" })).toBe("boom");
		expect(toolResultContent({ exitCode: 2, stdout: "", stderr: "" })).toBe("exited 2");
	});
	test("passes plain string results through", () => {
		expect(toolResultContent("File created successfully")).toBe(
			"File created successfully",
		);
	});
});

describe("parseGitDiff", () => {
	test("parses a new-file diff into one card with counts and hunk lines", () => {
		const raw = [
			"diff --git a/web-next/NOTE.md b/web-next/NOTE.md",
			"new file mode 100644",
			"index 0000000..376c071",
			"--- /dev/null",
			"+++ b/web-next/NOTE.md",
			"@@ -0,0 +1,2 @@",
			"+harness runtime online",
			"+resumed turn ok",
			"\\ No newline at end of file",
		].join("\n");
		const cards = parseGitDiff(raw);
		expect(cards).toHaveLength(1);
		expect(cards[0]).toMatchObject({
			file: "web-next/NOTE.md",
			additions: 2,
			deletions: 0,
		});
		expect(cards[0].lines).toEqual([
			{ kind: "add", text: "+harness runtime online" },
			{ kind: "add", text: "+resumed turn ok" },
		]);
	});

	test("splits a multi-file diff and counts add/del/context per file", () => {
		const raw = [
			"diff --git a/a.ts b/a.ts",
			"--- a/a.ts",
			"+++ b/a.ts",
			"@@ -1,3 +1,3 @@",
			" const x = 1;",
			"-const y = 2;",
			"+const y = 3;",
			" const z = 4;",
			"diff --git a/b.ts b/b.ts",
			"--- a/b.ts",
			"+++ b/b.ts",
			"@@ -0,0 +1 @@",
			"+export const flag = true;",
		].join("\n");
		const cards = parseGitDiff(raw);
		expect(cards.map((c) => c.file)).toEqual(["a.ts", "b.ts"]);
		expect(cards[0]).toMatchObject({ additions: 1, deletions: 1 });
		expect(cards[0].lines).toHaveLength(4); // 2 context + 1 add + 1 del
		expect(cards[1]).toMatchObject({ additions: 1, deletions: 0 });
	});

	test("returns no cards for an empty diff", () => {
		expect(parseGitDiff("")).toEqual([]);
	});
});

describe("uniqueDiffToolCallId", () => {
	test("is diff:<file> when nothing has claimed that id yet", () => {
		expect(uniqueDiffToolCallId("a.ts", new Set())).toBe("diff:a.ts");
	});

	// A real tool call id is never diff:<path>-shaped, but the id space is
	// shared, so a synthetic Diff row must not silently overwrite one that is.
	test("disambiguates against a real toolCallId already used this turn", () => {
		const seen = new Set(["diff:a.ts"]);
		expect(uniqueDiffToolCallId("a.ts", seen)).toBe("diff:a.ts#1");
	});

	test("keeps disambiguating past a single collision", () => {
		const seen = new Set(["diff:a.ts", "diff:a.ts#1", "diff:a.ts#2"]);
		expect(uniqueDiffToolCallId("a.ts", seen)).toBe("diff:a.ts#3");
	});
});
