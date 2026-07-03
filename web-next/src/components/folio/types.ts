/*
 * Shared Folio data shapes: the message metadata + custom data parts the
 * components consume. Messages are AI SDK UIMessages so #748 can stream
 * into the same components; everything visual rides in metadata/data parts.
 */
import type { UIMessage } from "ai";

/**
 * End-of-turn receipt numbers ("3 tools · 1 file · +3 −1 · 4 tests · 6.2s").
 * Only toolCount and durationMs are always known; the rest render when the
 * turn produced them (see lib/transcript/turn-stats.ts for the derivation).
 */
export interface TurnStatsData {
	toolCount: number;
	tokenCount?: number;
	durationMs: number;
	/** Distinct files changed by Edit/Write calls. */
	filesChanged?: number;
	/** Summed line delta across the turn's landed diffs. */
	additions?: number;
	deletions?: number;
	testsPassed?: number;
}

export interface FolioMetadata {
	/** Display name in the message label (e.g. "Michael", "Claude"). */
	author: string;
	/** Hover-revealed timestamp, preformatted (e.g. "9:41 am"). */
	stamp?: string;
	/** Current-turn focus cue: accent tick in the left gutter. */
	focal?: boolean;
	/** Older context recedes a hair (opacity). */
	recede?: boolean;
	/** Present on completed agent turns only. */
	turnStats?: TurnStatsData;
}

export interface DiffLine {
	kind: "context" | "add" | "del";
	text: string;
}

/** A landed edit surfaced as a contextual card. */
export interface DiffCardData {
	file: string;
	additions: number;
	deletions: number;
	/** Italic caption on the right (e.g. "edit landed · just now"). */
	note?: string;
	lines: DiffLine[];
}

export type FolioDataParts = {
	diff: DiffCardData;
	/** Transient provider status ("Cloning repo") — surfaced via onData, never a part. */
	status: { message: string };
};

export type FolioMessage = UIMessage<FolioMetadata, FolioDataParts>;
