import type { DynamicToolUIPart } from "ai";
import { describe, expect, it } from "vitest";
import {
	contextualOpenToolCallId,
	describeToolPart,
	formatTurnStats,
	highlightTestOutput,
	parseTestSummary,
} from "./ledger";
import type { FolioMessage } from "./types";

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

	it("renders a landed edit's diff as the body, with counts from the diff itself", () => {
		const diff = {
			file: "src/session/resume.ts",
			additions: 4,
			deletions: 1,
			lines: [{ kind: "add" as const, text: "+ throw new SessionNotFoundError(id);" }],
		};
		const row = describeToolPart(
			toolPart({
				toolName: "Edit",
				input: {
					file_path: "src/session/resume.ts",
					old_string: "return hydrate(record);",
					new_string: "if (!record) throw e;\nreturn hydrate(record);",
				},
				output: { content: "guard added", diff },
			}),
		);
		expect(row.body).toEqual({ kind: "diff", diff });
		// The diff's real counts win over the old/new-string line-count estimate.
		expect(row.meta).toEqual({ kind: "delta", additions: 4, deletions: 1 });
	});

	it("sanitizes a malformed persisted diff instead of rendering it broken", () => {
		const row = describeToolPart(
			toolPart({
				toolName: "Edit",
				output: {
					content: "guard added",
					diff: {
						file: "a.ts",
						additions: "not-a-number",
						deletions: null,
						lines: [
							{ kind: "add", text: "+ ok" },
							{ kind: "add", text: 42 }, // non-string text: dropped
							{ kind: "explode", text: "+ bogus kind" }, // bad kind: dropped
							"not even an object", // dropped
							{ kind: "del", text: "- also ok" },
						],
					},
				},
			}),
		);
		expect(row.body).toEqual({
			kind: "diff",
			diff: {
				file: "a.ts",
				// Falls back to counting the sanitized lines, not "NaN"/"+undefined".
				additions: 1,
				deletions: 1,
				lines: [
					{ kind: "add", text: "+ ok" },
					{ kind: "del", text: "- also ok" },
				],
			},
		});
		expect(row.meta).toEqual({ kind: "delta", additions: 1, deletions: 1 });
	});
});

describe("contextualOpenToolCallId", () => {
	function editPart(toolCallId: string, hasDiff: boolean): DynamicToolUIPart {
		return toolPart({
			toolCallId,
			toolName: "Edit",
			state: "output-available",
			output: hasDiff
				? {
						content: "landed",
						diff: { file: "a.ts", additions: 1, deletions: 0, lines: [] },
					}
				: "landed",
		});
	}

	function parts(...items: DynamicToolUIPart[]): FolioMessage["parts"] {
		return items as unknown as FolioMessage["parts"];
	}

	it("is the last part's toolCallId when it's a completed edit with a diff", () => {
		expect(contextualOpenToolCallId(parts(editPart("tool-3", true)))).toBe("tool-3");
	});

	it("is undefined once a newer part has landed after the edit", () => {
		const withTrailingText = [
			editPart("tool-3", true),
			{ type: "text", text: "Done." },
		] as unknown as FolioMessage["parts"];
		expect(contextualOpenToolCallId(withTrailingText)).toBeUndefined();

		const withTrailingTool = parts(editPart("tool-3", true), editPart("tool-4", false));
		expect(contextualOpenToolCallId(withTrailingTool)).toBeUndefined();
	});

	it("is undefined when the last tool call has no diff", () => {
		expect(contextualOpenToolCallId(parts(editPart("tool-3", false)))).toBeUndefined();
	});

	it("is undefined when the last tool call is still running", () => {
		const running = toolPart({
			toolCallId: "tool-3",
			toolName: "Edit",
			state: "input-available",
			output: undefined,
		} as Partial<DynamicToolUIPart>);
		expect(contextualOpenToolCallId(parts(running))).toBeUndefined();
	});

	it("is undefined for an empty parts list", () => {
		expect(contextualOpenToolCallId(parts())).toBeUndefined();
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

	it("slots in files, line delta, and tests when the turn produced them", () => {
		expect(
			formatTurnStats({
				toolCount: 3,
				tokenCount: 1100,
				durationMs: 6200,
				filesChanged: 1,
				additions: 3,
				deletions: 1,
				testsPassed: 4,
			}),
		).toBe("3 tools · 1 file · +3 −1 · 4 tests · 1.1k tokens · 6.2s");
	});

	it("omits figures the turn never produced", () => {
		expect(formatTurnStats({ toolCount: 0, durationMs: 500 })).toBe(
			"0 tools · 0.5s",
		);
	});
});
