/*
 * Shared Folio data shapes: the message metadata + custom data parts the
 * components consume. Messages are AI SDK UIMessages so #748 can stream
 * into the same components; everything visual rides in metadata/data parts.
 */
import type { UIMessage } from "ai";

/** End-of-turn receipt numbers ("4 tools · 3.2k tokens · 18.6s"). */
export interface TurnStatsData {
	toolCount: number;
	tokenCount: number;
	durationMs: number;
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
};

export type FolioMessage = UIMessage<FolioMetadata, FolioDataParts>;
