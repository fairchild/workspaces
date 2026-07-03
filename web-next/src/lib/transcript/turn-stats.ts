/*
 * Derives the end-of-turn receipt from a turn's StreamChunks — tool count,
 * files changed, line delta, tests passed come from the chunks themselves;
 * duration and token usage from the provider's `done` metadata. Used by the
 * chunk adapter's messageMetadata hook, so live streams and replayed logs
 * produce identical stats (the numbers are in the persisted events).
 */
import type { FolioMetadata, TurnStatsData } from "@/components/folio/types";
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
		filesChanged: changedFiles.size > 0 ? changedFiles.size : undefined,
		additions,
		deletions,
		testsPassed,
	};
}

/**
 * The assistant-message metadata for a turn: author immediately (fed to the
 * adapter's `start`), turn stats once the turn completed (fed to `finish`).
 */
export function folioTurnMetadata(
	chunks: readonly StreamChunk[],
): FolioMetadata {
	const turnStats = deriveTurnStats(chunks);
	return turnStats ? { author: AGENT_AUTHOR, turnStats } : { author: AGENT_AUTHOR };
}
