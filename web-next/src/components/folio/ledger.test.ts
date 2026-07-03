import type { DynamicToolUIPart } from "ai";
import { describe, expect, it } from "vitest";
import {
	describeToolPart,
	formatTurnStats,
	highlightTestOutput,
	parseTestSummary,
} from "./ledger";

function toolPart(overrides: Partial<DynamicToolUIPart>): DynamicToolUIPart {
	return {
		type: "dynamic-tool",
		toolCallId: "tool-1",
		toolName: "Read",
		state: "output-available",
		input: {},
		output: "",
		...overrides,
	} as DynamicToolUIPart;
}

describe("describeToolPart", () => {
	it("renders Read with a file subject and an explicit summary", () => {
		const row = describeToolPart(
			toolPart({
				input: { file_path: "src/session/session.test.ts" },
				output: { content: "it(...)", summary: "41 lines" },
			}),
		);
		expect(row).toMatchObject({
			verb: "Read",
			subject: "src/session/session.test.ts",
			meta: { kind: "text", text: "41 lines" },
			body: { kind: "code", content: "it(...)" },
		});
	});

	it("falls back to a line count for Read without a summary", () => {
		const row = describeToolPart(
			toolPart({ input: { file_path: "a.ts" }, output: "one\ntwo\nthree" }),
		);
		expect(row.meta).toEqual({ kind: "text", text: "3 lines" });
	});

	it("derives an Edit delta from old/new strings", () => {
		const row = describeToolPart(
			toolPart({
				toolName: "Edit",
				input: {
					file_path: "src/session/resume.ts",
					old_string: "return hydrate(record);",
					new_string: "if (!record) {\n\tthrow e;\n}\nreturn hydrate(record);",
				},
				output: "guard added",
			}),
		);
		expect(row.verb).toBe("Edit");
		expect(row.meta).toEqual({ kind: "delta", additions: 4, deletions: 1 });
	});

	it("recognizes a passing test run and summarizes it", () => {
		const output = [
			"✓ src/a.test.ts (6 tests) 128ms",
			"",
			"Test Files  3 passed (3)",
			"     Tests  28 passed (28)",
			"  Duration  1.21s",
		].join("\n");
		const row = describeToolPart(
			toolPart({ toolName: "Bash", input: { command: "pnpm test" }, output }),
		);
		expect(row.verb).toBe("Ran");
		expect(row.subject).toBe("pnpm test");
		expect(row.meta).toEqual({ kind: "text", text: "28 passed · 1.21s" });
		expect(row.body).toMatchObject({ kind: "test-output", passed: true });
	});

	it("marks failed tool calls", () => {
		const row = describeToolPart(
			toolPart({
				state: "output-error",
				errorText: "boom",
				output: undefined,
			} as Partial<DynamicToolUIPart>),
		);
		expect(row.meta).toEqual({ kind: "text", text: "failed" });
		expect(row.body).toEqual({ kind: "code", content: "boom" });
	});

	it("omits body and meta while a call is still running", () => {
		const row = describeToolPart(
			toolPart({
				state: "input-available",
				input: { command: "pnpm test" },
				toolName: "Bash",
				output: undefined,
			} as Partial<DynamicToolUIPart>),
		);
		expect(row).toEqual({ verb: "Ran", subject: "pnpm test" });
	});
});

describe("parseTestSummary", () => {
	it("takes the final passed count and the Duration line", () => {
		expect(
			parseTestSummary("Test Files 3 passed (3)\nTests 28 passed (28)\nDuration 1.21s"),
		).toBe("28 passed · 1.21s");
	});

	it("returns undefined for non-test output", () => {
		expect(parseTestSummary("compiled successfully")).toBeUndefined();
	});
});

describe("highlightTestOutput", () => {
	it("tones check marks and passed counts", () => {
		const [checkLine, , totalLine] = highlightTestOutput(
			"✓ src/a.test.ts (6 tests)\n\n Tests  28 passed (28)",
		);
		expect(checkLine[0]).toEqual({ text: "✓", tone: "ok" });
		expect(totalLine).toContainEqual({ text: "28 passed", tone: "strong" });
	});

	it("marks failures", () => {
		const [line] = highlightTestOutput("✗ src/a.test.ts");
		expect(line[0]).toEqual({ text: "✗", tone: "fail" });
	});
});

describe("formatTurnStats", () => {
	it("formats the prototype receipt", () => {
		expect(
			formatTurnStats({ toolCount: 4, tokenCount: 3200, durationMs: 18600 }),
		).toBe("4 tools · 3.2k tokens · 18.6s");
	});

	it("handles singulars, small counts, and minutes", () => {
		expect(
			formatTurnStats({ toolCount: 1, tokenCount: 950, durationMs: 75000 }),
		).toBe("1 tool · 950 tokens · 1m 15s");
	});

	it("trims trailing .0 from token counts", () => {
		expect(
			formatTurnStats({ toolCount: 2, tokenCount: 12000, durationMs: 900 }),
		).toBe("2 tools · 12k tokens · 0.9s");
	});
});
