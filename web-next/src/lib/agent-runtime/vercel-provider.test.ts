import { describe, expect, test } from "vitest";
import {
	canonicalToolName,
	errorText,
	mapFullStream,
	parseGitDiff,
	toolResultContent,
} from "./vercel-provider";
import type { StreamChunk } from "./stream-chunk";

type Part = { type: string; [k: string]: unknown };

async function collect(parts: Part[]): Promise<StreamChunk[]> {
	async function* source(): AsyncIterable<Part> {
		for (const part of parts) yield part;
	}
	const out: StreamChunk[] = [];
	for await (const chunk of mapFullStream(source(), 0)) out.push(chunk);
	return out;
}

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
			{ type: "finish", finishReason: "stop", totalUsage: { outputTokens: 42 } },
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
			{ type: "finish", finishReason: "stop", totalUsage: { outputTokens: 7 } },
		]);
		const done = chunks.at(-1);
		expect(done?.type).toBe("done");
		expect(done?.metadata).toMatchObject({ tokenCount: 7 });
		expect(typeof done?.metadata?.durationMs).toBe("number");
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
