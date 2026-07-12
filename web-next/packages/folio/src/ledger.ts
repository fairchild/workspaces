/*
 * Maps AI SDK dynamic-tool parts onto tool-ledger row content: a verb, a
 * subject, a right-aligned meta summary, and an expandable body. Pure logic
 * so #748 can point real tool outputs at the same rows without UI changes.
 * A landed edit's diff (when its structured output carries one) is a body
 * kind like any other — the Edit ledger row is the diff's one home; there
 * is no separate free-floating diff card in the transcript (#790).
 */
import { isDynamicToolUIPart, type DynamicToolUIPart } from "ai";
import { formatTokenCount } from "./format";
import type { DiffCardData, DiffLine, FolioMessage, TurnStatsData } from "./types";

export type LedgerMeta =
	| { kind: "text"; text: string }
	| { kind: "delta"; additions: number; deletions: number };

export type LedgerBody =
	| { kind: "code"; content: string }
	| { kind: "test-output"; content: string; passed: boolean }
	| { kind: "diff"; diff: DiffCardData };

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

/** Tool outputs may carry a display summary and/or the edit's landed diff. */
interface StructuredToolOutput {
	content: string;
	summary?: string;
	diff?: DiffCardData;
}

function asRecord(value: unknown): Record<string, unknown> {
	return typeof value === "object" && value !== null
		? (value as Record<string, unknown>)
		: {};
}

function asOptionalString(value: unknown): string | undefined {
	return typeof value === "string" ? value : undefined;
}

const DIFF_LINE_KINDS = new Set<DiffLine["kind"]>(["context", "add", "del"]);

function asDiffLine(value: unknown): DiffLine | undefined {
	const record = asRecord(value);
	const kind = record.kind;
	if (typeof kind !== "string" || !DIFF_LINE_KINDS.has(kind as DiffLine["kind"]))
		return undefined;
	const text = asOptionalString(record.text);
	if (text === undefined) return undefined;
	return { kind: kind as DiffLine["kind"], text };
}

/**
 * Duck-types a diff payload defensively — this can be an old/malformed
 * persisted event, not just a fresh one this version produced. A line that
 * doesn't match the expected shape is dropped rather than rendered broken,
 * and additions/deletions fall back to counting the (sanitized) lines, so a
 * corrupted row can't surface as a literal "+undefined −undefined".
 */
function asDiff(value: unknown): DiffCardData | undefined {
	const record = asRecord(value);
	if (!Array.isArray(record.lines)) return undefined;
	const lines = record.lines
		.map(asDiffLine)
		.filter((line): line is DiffLine => line !== undefined);
	return {
		file: asOptionalString(record.file) ?? "",
		additions:
			typeof record.additions === "number"
				? record.additions
				: lines.filter((line) => line.kind === "add").length,
		deletions:
			typeof record.deletions === "number"
				? record.deletions
				: lines.filter((line) => line.kind === "del").length,
		lines,
	};
}

function normalizeOutput(output: unknown): StructuredToolOutput | undefined {
	if (typeof output === "string") return { content: output };
	const record = asRecord(output);
	const content = asOptionalString(record.content);
	if (content === undefined) return undefined;
	return {
		content,
		summary: asOptionalString(record.summary),
		diff: asDiff(record.diff),
	};
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

	const body: LedgerBody =
		output.diff !== undefined
			? { kind: "diff", diff: output.diff }
			: looksLikeTestOutput(output.content)
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
	// The diff's own counts are exact (derived from the real hunk); prefer
	// them over a summary string or an old/new-string line count estimate.
	if (output.diff !== undefined)
		return {
			kind: "delta",
			additions: output.diff.additions,
			deletions: output.diff.deletions,
		};
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

// --- the contextual moment ---------------------------------------------------

/**
 * The toolCallId of the "just landed" contextual moment: the message's very
 * last part, if it's a completed tool call whose body is a diff. Its ledger
 * row starts open — the diff surfacing because the edit landed, per Folio's
 * "contextual moments are the star" principle. Any later part (more prose,
 * another tool call) supersedes it, so this reports nothing once something
 * newer has arrived; the row's caller re-keys on this id and remounts
 * collapsed when it changes, which is the auto-collapse.
 */
export function contextualOpenToolCallId(
	parts: FolioMessage["parts"],
): string | undefined {
	const last = parts.at(-1);
	if (last === undefined || !isDynamicToolUIPart(last)) return undefined;
	if (last.state !== "output-available") return undefined;
	return describeToolPart(last).body?.kind === "diff" ? last.toolCallId : undefined;
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
