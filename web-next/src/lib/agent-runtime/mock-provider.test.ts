import { describe, expect, test } from "vitest";
import { deriveTurnStats } from "../transcript/turn-stats";
import { mockCodingTurn, mockProvider } from "./mock-provider";
import { DEFAULT_MODEL } from "./models";
import type { StreamChunk } from "./stream-chunk";

/** The whole scripted turn, without waiting out the streaming pace. */
async function fullTurn(userMessage: string, model?: string): Promise<StreamChunk[]> {
	const chunks: StreamChunk[] = [];
	for await (const chunk of mockCodingTurn(
		userMessage,
		() => Promise.resolve(),
		model,
	)) {
		chunks.push(chunk);
	}
	return chunks;
}

describe("mockCodingTurn", () => {
	test("echoes the user message in the opening prose", async () => {
		const chunks = await fullTurn("Fix the flaky retry");
		const prose = chunks
			.filter((chunk) => chunk.type === "text")
			.map((chunk) => chunk.content)
			.join("");
		expect(prose).toContain('You asked: "Fix the flaky retry"');
	});

	test("thinks first: a reasoning trace leads, before any prose or tool", async () => {
		const chunks = await fullTurn("go");
		const reasoning = chunks
			.filter((chunk) => chunk.type === "reasoning")
			.map((chunk) => chunk.content)
			.join("");
		expect(reasoning).toContain("SessionNotFoundError");
		// The thinking block precedes the visible answer and the first tool call.
		const firstReasoning = chunks.findIndex((c) => c.type === "reasoning");
		const firstText = chunks.findIndex((c) => c.type === "text");
		const firstTool = chunks.findIndex((c) => c.type === "tool_use");
		expect(firstReasoning).toBeGreaterThanOrEqual(0);
		expect(firstReasoning).toBeLessThan(firstText);
		expect(firstReasoning).toBeLessThan(firstTool);
	});

	test("reproduces (failing), fixes, then re-runs (passing)", async () => {
		const chunks = await fullTurn("go");
		const calls = chunks.filter((chunk) => chunk.type === "tool_use");
		expect(calls.map((chunk) => chunk.metadata?.toolName)).toEqual([
			"Bash",
			"Read",
			"Edit",
			"Bash",
		]);
		const results = chunks.filter((chunk) => chunk.type === "tool_result");
		expect(results).toHaveLength(4);
		// The first test run fails; the run after the edit passes.
		const failed = results.filter((chunk) => chunk.metadata?.isError === true);
		expect(failed).toHaveLength(1);
		// Each tool announces itself as a status first (the activity line).
		const statuses = chunks
			.filter((chunk) => chunk.type === "status")
			.map((chunk) => chunk.content);
		expect(statuses).toContain("Reading `src/lib/session.ts`");
		expect(statuses).toContain("Running `pnpm test session`");
	});

	test("the Edit result carries the landed diff", async () => {
		const chunks = await fullTurn("go");
		const editResult = chunks.find(
			(chunk) =>
				chunk.type === "tool_result" && chunk.metadata?.toolUseId === "tool-3",
		);
		expect(editResult?.metadata?.diff).toMatchObject({
			file: "src/lib/session.ts",
			additions: 3,
			deletions: 1,
		});
	});

	test("the turn derives a complete receipt", async () => {
		const chunks = await fullTurn("go");
		const stats = deriveTurnStats(chunks);
		expect(stats).toMatchObject({
			toolCount: 4,
			filesChanged: 1,
			additions: 3,
			deletions: 1,
			testsPassed: 4,
		});
		expect(stats?.tokenCount).toBeGreaterThan(0);
	});

	test("the provider registers as `mock` and runs the scripted turn", async () => {
		expect(mockProvider.id).toBe("mock");
		const iterator = mockProvider.runTurn({
			sessionId: "s",
			userMessage: "hi",
		})[Symbol.asyncIterator]();
		const first = await iterator.next();
		expect(first.value).toEqual({ type: "status", content: "Starting sandbox" });
		await iterator.return?.(undefined);
	});

	test("records the default model on the terminal done chunk when none is requested (#824)", async () => {
		const chunks = await fullTurn("go");
		const done = chunks.find((chunk) => chunk.type === "done");
		expect(done?.metadata?.model).toBe(DEFAULT_MODEL);
	});

	test("records an explicit model override on the terminal done chunk (#824)", async () => {
		const chunks = await fullTurn("go", "claude-haiku-4-5");
		const done = chunks.find((chunk) => chunk.type === "done");
		expect(done?.metadata?.model).toBe("claude-haiku-4-5");
	});

	test("also records a plausible contextTokens figure alongside tokenCount", async () => {
		const chunks = await fullTurn("go");
		const done = chunks.find((chunk) => chunk.type === "done");
		expect(done?.metadata?.contextTokens).toBeGreaterThan(0);
	});
});
