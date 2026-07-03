import { describe, expect, test } from "vitest";
import type { StreamChunk } from "../agent-runtime/stream-chunk";
import { deriveTurnStats, folioTurnMetadata } from "./turn-stats";

const done = (metadata?: Record<string, unknown>): StreamChunk => ({
	type: "done",
	content: "",
	metadata,
});

function edit(filePath: string): StreamChunk {
	return {
		type: "tool_use",
		content: "Edit",
		metadata: { toolName: "Edit", input: { file_path: filePath } },
	};
}

describe("deriveTurnStats", () => {
	test("returns undefined while the turn is still open (no done chunk)", () => {
		expect(
			deriveTurnStats([{ type: "text", content: "working…" }]),
		).toBeUndefined();
	});

	test("counts tools and takes duration/tokens from the done metadata", () => {
		const stats = deriveTurnStats([
			{ type: "tool_use", content: "Read", metadata: { toolName: "Read" } },
			{ type: "tool_use", content: "Bash", metadata: { toolName: "Bash" } },
			done({ durationMs: 6200, tokenCount: 1100 }),
		]);
		expect(stats).toEqual({
			toolCount: 2,
			durationMs: 6200,
			tokenCount: 1100,
		});
	});

	test("counts distinct changed files across Edit/Write calls", () => {
		const stats = deriveTurnStats([
			edit("a.ts"),
			edit("a.ts"),
			edit("b.ts"),
			{ type: "tool_use", content: "Read", metadata: { toolName: "Read", input: { file_path: "c.ts" } } },
			done(),
		]);
		expect(stats?.filesChanged).toBe(2); // reads don't change files
		expect(stats?.toolCount).toBe(4);
	});

	test("sums the line delta over the turn's diff results", () => {
		const stats = deriveTurnStats([
			{ type: "tool_result", content: "ok", metadata: { diff: { additions: 3, deletions: 1 } } },
			{ type: "tool_result", content: "ok", metadata: { diff: { additions: 2, deletions: 0 } } },
			done(),
		]);
		expect(stats).toMatchObject({ additions: 5, deletions: 1 });
	});

	test("reads the last test-run figure from tool outputs", () => {
		const stats = deriveTurnStats([
			{ type: "tool_result", content: "Tests  3 passed (3)" },
			{ type: "tool_result", content: "Tests  4 passed (4)" },
			done(),
		]);
		expect(stats?.testsPassed).toBe(4);
	});

	test("a done chunk without metadata still yields a receipt", () => {
		expect(deriveTurnStats([done()])).toEqual({
			toolCount: 0,
			durationMs: 0,
		});
	});
});

describe("folioTurnMetadata", () => {
	test("is author-only before the turn completes", () => {
		expect(folioTurnMetadata([])).toEqual({ author: "Claude" });
	});

	test("carries the derived stats once the turn is done", () => {
		expect(folioTurnMetadata([done({ durationMs: 10 })])).toEqual({
			author: "Claude",
			turnStats: { toolCount: 0, durationMs: 10 },
		});
	});
});
