import { describe, expect, test } from "vitest";
import type { FolioMessage } from "@/components/folio/types";
import type { StreamChunk } from "../agent-runtime/stream-chunk";
import {
	deriveContextLabel,
	deriveTurnError,
	deriveTurnStats,
	folioTurnMetadata,
} from "./turn-stats";

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

	test("extracts the real contextTokens figure from done metadata (#824)", () => {
		const stats = deriveTurnStats([done({ durationMs: 10, contextTokens: 2000 })]);
		expect(stats).toMatchObject({ contextTokens: 2000 });
	});
});

describe("deriveContextLabel", () => {
	function assistantMessage(contextTokens?: number): FolioMessage {
		return {
			id: "m",
			role: "assistant",
			parts: [],
			metadata:
				contextTokens === undefined
					? { author: "Claude" }
					: { author: "Claude", turnStats: { toolCount: 0, durationMs: 0, contextTokens } },
		};
	}

	test("undefined when no turn has reported a context figure", () => {
		expect(deriveContextLabel([assistantMessage()])).toBeUndefined();
	});

	test("formats the most recent completed turn's figure", () => {
		expect(
			deriveContextLabel([assistantMessage(500), assistantMessage(2300)]),
		).toBe("2.3k ctx");
	});

	test("looks back past a trailing turn that hasn't reported one yet", () => {
		expect(deriveContextLabel([assistantMessage(500), assistantMessage()])).toBe(
			"500 ctx",
		);
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

	test("carries the failure instead of a receipt on a failed turn (#808)", () => {
		expect(
			folioTurnMetadata([
				{ type: "error", content: "sandbox died" },
				done({ aborted: true }),
			]),
		).toEqual({ author: "Claude", error: "sandbox died" });
	});
});

describe("deriveTurnError (#808)", () => {
	test("undefined for a normal, still-open turn", () => {
		expect(deriveTurnError([{ type: "text", content: "working…" }])).toBeUndefined();
	});

	test("undefined for a cleanly completed turn", () => {
		expect(deriveTurnError([done({ durationMs: 10 })])).toBeUndefined();
	});

	test("the error chunk's text, when one is present", () => {
		expect(
			deriveTurnError([
				{ type: "text", content: "partial answer" },
				{ type: "error", content: "sandbox died" },
				done({ aborted: true }),
			]),
		).toBe("sandbox died");
	});

	test("a generic message for an aborted done with no explicit error chunk", () => {
		expect(deriveTurnError([done({ aborted: true })])).toBe(
			"Turn interrupted before completion.",
		);
	});

	test("a generic message when the error chunk carries no content", () => {
		expect(
			deriveTurnError([{ type: "error", content: "" }, done({ aborted: true })]),
		).toBe("The turn failed.");
	});

	test("a done chunk without aborted metadata is not a failure", () => {
		expect(deriveTurnError([done()])).toBeUndefined();
	});
});
