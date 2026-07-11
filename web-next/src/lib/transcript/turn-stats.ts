/*
 * Derives the end-of-turn receipt from a turn's StreamChunks — tool count,
 * files changed, line delta, tests passed come from the chunks themselves;
 * duration and token usage from the provider's `done` metadata. Used by the
 * chunk adapter's messageMetadata hook, so live streams and replayed logs
 * produce identical stats (the numbers are in the persisted events).
 */
import {
	formatTokenCount,
	type FolioMessage,
	type FolioMetadata,
	type TurnStatsData,
} from "@fairchild/folio";
import type { StreamChunk } from "../agent-runtime/stream-chunk";

/** The agent's display name on assistant messages (single-agent for now). */
const AGENT_AUTHOR = "Claude";

function asNumber(value: unknown): number | undefined {
	return typeof value === "number" && Number.isFinite(value)
		? value
		: undefined;
}

/** Last "N passed" figure in test-runner output, or undefined. */
function parseTestsPassed(output: string): number | undefined {
	const match = [...output.matchAll(/(\d+)\s+passed/g)].at(-1);
	return match ? Number(match[1]) : undefined;
}

/**
 * The turn's failure text, or undefined if it hasn't failed. An `error`
 * chunk (a live provider fault, or the synthesized message
 * `closeAbandonedTurn`/turn-ingest's catch write for an interrupted run) wins
 * outright; a `done` chunk carrying `metadata.aborted` with no explicit error
 * chunk (defensive — the two are always paired in practice) falls back to a
 * generic message. Undefined for a normal, still-open, or cleanly completed
 * turn (see `folioTurnMetadata`, which this feeds).
 */
export function deriveTurnError(chunks: readonly StreamChunk[]): string | undefined {
	const errorChunk = chunks.find((chunk) => chunk.type === "error");
	if (errorChunk) return errorChunk.content.length > 0 ? errorChunk.content : "The turn failed.";
	const doneChunk = chunks.find((chunk) => chunk.type === "done");
	if (doneChunk?.metadata?.aborted === true) return "Turn interrupted before completion.";
	return undefined;
}

/**
 * Stats for a completed turn, or undefined while the turn is still open
 * (no `done` chunk yet) — an unfinished turn gets no receipt.
 *
 * - toolCount: `tool_use` chunks.
 * - filesChanged: distinct `input.file_path` across Edit/Write calls.
 * - additions/deletions: summed over `tool_result` diff metadata (the same
 *   diffs the transcript surfaces as cards).
 * - testsPassed: last "N passed" across tool outputs.
 * - durationMs/tokenCount: reported by the provider on the `done` chunk.
 */
export function deriveTurnStats(
	chunks: readonly StreamChunk[],
): TurnStatsData | undefined {
	const done = chunks.find((chunk) => chunk.type === "done");
	if (!done) return undefined;

	let toolCount = 0;
	const changedFiles = new Set<string>();
	let additions: number | undefined;
	let deletions: number | undefined;
	let testsPassed: number | undefined;

	for (const chunk of chunks) {
		if (chunk.type === "tool_use") {
			toolCount += 1;
			const metadata = chunk.metadata ?? {};
			const input = metadata.input as Record<string, unknown> | undefined;
			const filePath = input?.file_path;
			const toolName = metadata.toolName;
			if (
				(toolName === "Edit" || toolName === "Write") &&
				typeof filePath === "string"
			) {
				changedFiles.add(filePath);
			}
		} else if (chunk.type === "tool_result") {
			const diff = chunk.metadata?.diff as
				| { additions?: unknown; deletions?: unknown }
				| undefined;
			if (diff !== undefined) {
				additions = (additions ?? 0) + (asNumber(diff.additions) ?? 0);
				deletions = (deletions ?? 0) + (asNumber(diff.deletions) ?? 0);
			}
			testsPassed = parseTestsPassed(chunk.content) ?? testsPassed;
		}
	}

	return {
		toolCount,
		durationMs: asNumber(done.metadata?.durationMs) ?? 0,
		tokenCount: asNumber(done.metadata?.tokenCount),
		contextTokens: asNumber(done.metadata?.contextTokens),
		filesChanged: changedFiles.size > 0 ? changedFiles.size : undefined,
		additions,
		deletions,
		testsPassed,
	};
}

/**
 * The assistant-message metadata for a turn: author immediately (fed to the
 * adapter's `start`), then either the turn's failure or its stats once the
 * turn completed (fed to `finish`) — a failed turn gets `error` instead of a
 * `turnStats` receipt, never both.
 */
export function folioTurnMetadata(
	chunks: readonly StreamChunk[],
): FolioMetadata {
	const error = deriveTurnError(chunks);
	if (error) return { author: AGENT_AUTHOR, error };
	const turnStats = deriveTurnStats(chunks);
	return turnStats ? { author: AGENT_AUTHOR, turnStats } : { author: AGENT_AUTHOR };
}

/**
 * The status line's real "N ctx" figure (#824): the most recent completed
 * turn's total input tokens — what the model actually saw last, the best
 * available proxy for current context usage. Undefined when no turn has
 * completed yet, or none reported the figure — the status line hides the
 * segment rather than showing a fake "0 ctx".
 */
export function deriveContextLabel(
	messages: readonly FolioMessage[],
): string | undefined {
	for (let i = messages.length - 1; i >= 0; i -= 1) {
		const contextTokens = messages[i].metadata?.turnStats?.contextTokens;
		if (contextTokens !== undefined) return `${formatTokenCount(contextTokens)} ctx`;
	}
	return undefined;
}
