import { describe, expect, test } from "vitest";
import { deriveTurnStats } from "../transcript/turn-stats";
import { mockCodingTurn, mockProvider } from "./mock-provider";
import type { StreamChunk } from "./stream-chunk";

/** The whole scripted turn, without waiting out the streaming pace. */
async function fullTurn(userMessage: string): Promise<StreamChunk[]> {
	const chunks: StreamChunk[] = [];
	for await (const chunk of mockCodingTurn(userMessage, () => Promise.resolve())) {
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

	test("runs the Read → Edit → Bash script with paired results", async () => {
		const chunks = await fullTurn("go");
		const calls = chunks.filter((chunk) => chunk.type === "tool_use");
		expect(calls.map((chunk) => chunk.metadata?.toolName)).toEqual([
			"Read",
			"Edit",
			"Bash",
		]);
		const results = chunks.filter((chunk) => chunk.type === "tool_result");
		expect(results).toHaveLength(3);
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
				chunk.type === "tool_result" && chunk.metadata?.toolUseId === "tool-2",
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
			toolCount: 3,
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
});
