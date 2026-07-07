/*
 * Maps AI SDK dynamic-tool parts onto tool-ledger row content: a verb, a
 * subject, a right-aligned meta summary, and an expandable body. Pure logic
 * so #748 can point real tool outputs at the same rows without UI changes.
 */
import type { DynamicToolUIPart } from "ai";
import type { TurnStatsData } from "./types";

export type LedgerMeta =
	| { kind: "text"; text: string }
	| { kind: "delta"; additions: number; deletions: number };

export type LedgerBody =
	| { kind: "code"; content: string }
	| { kind: "test-output"; content: string; passed: boolean };

export interface LedgerRowModel {
	verb: string;
	subject: string;
	meta?: LedgerMeta;
	body?: LedgerBody;
}

/** Ledger verbs for well-known tools; unknown tools show their own name. */
const TOOL_VERBS: Record<string, string> = {
	Read: "Read",
	Edit: "Edit",
	Write: "Wrote",
	Bash: "Ran",
};

/** Tool outputs may carry a display summary next to their content. */
interface StructuredToolOutput {
	content: string;
	summary?: string;
}

function asRecord(value: unknown): Record<string, unknown> {
	return typeof value === "object" && value !== null
		? (value as Record<string, unknown>)
		: {};
}

function asOptionalString(value: unknown): string | undefined {
	return typeof value === "string" ? value : undefined;
}

function normalizeOutput(output: unknown): StructuredToolOutput | undefined {
	if (typeof output === "string") return { content: output };
	const record = asRecord(output);
	const content = asOptionalString(record.content);
	if (content === undefined) return undefined;
	return { content, summary: asOptionalString(record.summary) };
}

function countLines(text: string): number {
	return text.split("\n").length;
}

/** "28 passed · 1.21s" from vitest-style output, or undefined. */
export function parseTestSummary(output: string): string | undefined {
	const passedMatches = [...output.matchAll(/(\d+)\s+passed/g)];
	const passed = passedMatches.at(-1)?.[1];
	if (passed === undefined) return undefined;
	const duration = output.match(/Duration\s+([\d.]+\s?m?s)/i)?.[1];
	return duration ? `${passed} passed · ${duration}` : `${passed} passed`;
}

function looksLikeTestOutput(content: string): boolean {
	return /^\s*[✓✗×]/m.test(content) || /\d+\s+passed/.test(content);
}

export function describeToolPart(part: DynamicToolUIPart): LedgerRowModel {
	const input = asRecord(part.input);
	const verb = TOOL_VERBS[part.toolName] ?? part.toolName;
	const subject =
		asOptionalString(input.file_path) ??
		asOptionalString(input.command) ??
		part.toolName;

	if (part.state === "output-error") {
		return {
			verb,
			subject,
			meta: { kind: "text", text: "failed" },
			body: { kind: "code", content: part.errorText },
		};
	}
	const output =
		part.state === "output-available" ? normalizeOutput(part.output) : undefined;
	if (output === undefined) return { verb, subject };

	const body: LedgerBody = looksLikeTestOutput(output.content)
		? {
				kind: "test-output",
				content: output.content,
				passed: !/\d+\s+failed|[✗×]/.test(output.content),
			}
		: { kind: "code", content: output.content };

	return { verb, subject, meta: deriveMeta(part, input, output), body };
}

function deriveMeta(
	part: DynamicToolUIPart,
	input: Record<string, unknown>,
	output: StructuredToolOutput,
): LedgerMeta | undefined {
	if (output.summary !== undefined)
		return { kind: "text", text: output.summary };
	const oldString = asOptionalString(input.old_string);
	const newString = asOptionalString(input.new_string);
	if (part.toolName === "Edit" && oldString !== undefined && newString !== undefined) {
		return {
			kind: "delta",
			additions: countLines(newString),
			deletions: countLines(oldString),
		};
	}
	const testSummary = parseTestSummary(output.content);
	if (testSummary !== undefined) return { kind: "text", text: testSummary };
	if (part.toolName === "Read")
		return { kind: "text", text: `${countLines(output.content)} lines` };
	return undefined;
}

// --- test-output highlighting -----------------------------------------------

export interface OutputSegment {
	text: string;
	tone: "plain" | "ok" | "fail" | "strong";
}

/**
 * Splits test output into per-line segments: leading check marks read as
 * pass/fail, "N passed" counts read as strong — the prototype's quiet
 * highlighting of a green run.
 */
export function highlightTestOutput(content: string): OutputSegment[][] {
	return content.split("\n").map((line) => {
		const segments: OutputSegment[] = [];
		const mark = line.match(/^(\s*)([✓✗×])/);
		let rest = line;
		if (mark) {
			if (mark[1]) segments.push({ text: mark[1], tone: "plain" });
			segments.push({ text: mark[2], tone: mark[2] === "✓" ? "ok" : "fail" });
			rest = line.slice(mark[0].length);
		}
		let cursor = 0;
		for (const match of rest.matchAll(/\d+ passed/g)) {
			if (match.index > cursor)
				segments.push({ text: rest.slice(cursor, match.index), tone: "plain" });
			segments.push({ text: match[0], tone: "strong" });
			cursor = match.index + match[0].length;
		}
		if (cursor < rest.length)
			segments.push({ text: rest.slice(cursor), tone: "plain" });
		return segments;
	});
}

// --- end-of-turn receipt ----------------------------------------------------

/** "820" / "3.2k" — shared with the status line's context figure (#824). */
export function formatTokenCount(count: number): string {
	if (count < 1000) return String(count);
	return `${(count / 1000).toFixed(1).replace(/\.0$/, "")}k`;
}

function formatDuration(ms: number): string {
	const seconds = ms / 1000;
	if (seconds < 60) return `${seconds.toFixed(1)}s`;
	return `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s`;
}

function plural(count: number, noun: string): string {
	return `${count} ${noun}${count === 1 ? "" : "s"}`;
}

/**
 * "4 tools · 3.2k tokens · 18.6s" — optional figures (files, line delta,
 * tests) slot in when the turn produced them, in workflow order:
 * tools · files · delta · tests · tokens · duration.
 */
export function formatTurnStats(stats: TurnStatsData): string {
	const figures = [plural(stats.toolCount, "tool")];
	if (stats.filesChanged !== undefined)
		figures.push(plural(stats.filesChanged, "file"));
	if (stats.additions !== undefined || stats.deletions !== undefined)
		figures.push(`+${stats.additions ?? 0} −${stats.deletions ?? 0}`);
	if (stats.testsPassed !== undefined)
		figures.push(plural(stats.testsPassed, "test"));
	if (stats.tokenCount !== undefined)
		figures.push(`${formatTokenCount(stats.tokenCount)} tokens`);
	figures.push(formatDuration(stats.durationMs));
	return figures.join(" · ");
}
