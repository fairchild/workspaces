/*
 * Shared Folio data shapes: the message metadata + custom data parts the
 * components consume. Messages are AI SDK UIMessages so #748 can stream
 * into the same components; everything visual rides in metadata/data parts.
 * A landed edit has one home — its Edit tool part's own structured output
 * (see ledger.ts's LedgerBody "diff" kind) — so there is no separate diff
 * data part here.
 */
import type { UIMessage } from "ai";

export type ApprovalDecision = "allow" | "deny";
export type ApprovalResolvedBy = "user" | "timeout" | "abort";

export interface ConfigReceiptFile {
	path: string;
	basename: string;
	sha256: string;
}

export interface SkippedConfigReceiptFile {
	path: string;
	basename: string;
	reason: string;
}

export interface ConfigReceipt {
	envVar: string;
	loaded: ConfigReceiptFile[];
	skipped: SkippedConfigReceiptFile[];
}

/**
 * End-of-turn receipt numbers ("3 tools · 1 file · +3 −1 · 4 tests · 6.2s").
 * Only toolCount and durationMs are always known; the rest render when the
 * turn produced them (see lib/transcript/turn-stats.ts for the derivation).
 */
export interface TurnStatsData {
	toolCount: number;
	tokenCount?: number;
	/**
	 * The turn's total input (context) tokens — the real figure the session
	 * status line's "N ctx" reads (#824), reported by the provider's `done`
	 * chunk. Undefined for turns that predate this field or ran on a provider
	 * that doesn't report it (the status line hides the figure, not a fake 0).
	 */
	contextTokens?: number;
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
	/**
	 * Present when the turn ended in a stream error or was interrupted before
	 * completion (see lib/transcript/turn-stats.ts's `deriveTurnError`) —
	 * mutually exclusive with `turnStats`. The message this renders holds
	 * whatever content streamed before the failure (possibly none).
	 */
	error?: string;
}

export interface DiffLine {
	kind: "context" | "add" | "del";
	text: string;
}

/** A landed edit's diff, rendered inside its Edit ledger row's body. */
export interface DiffCardData {
	file: string;
	additions: number;
	deletions: number;
	/** Unused by rendering; kept on the wire for provenance/debugging. */
	note?: string;
	lines: DiffLine[];
}

export type ApprovalPartData =
	| {
			state: "pending";
			requestId: string;
			summary: string;
			toolName: string;
			inputSummary: string;
			expiresAt: string;
	  }
	| {
			state: "resolved";
			requestId: string;
			summary: string;
			toolName: string;
			inputSummary: string;
			expiresAt?: string;
			decision: ApprovalDecision;
			resolvedBy: ApprovalResolvedBy;
	  }
	| {
			/** The turn ended (stop, crash, error) with the request unanswered. */
			state: "cancelled";
			requestId: string;
			summary: string;
			toolName: string;
			inputSummary: string;
	  };

export type FolioDataParts = {
	/** Transient provider status ("Cloning repo") — surfaced via onData, never a part. */
	status: { message: string };
	/** Durable permission request/receipt rendered in the transcript (#982). */
	approval: ApprovalPartData;
	/** Durable harness config receipt rendered quietly at turn start (#985). */
	"config-receipt": Pick<ConfigReceipt, "loaded" | "skipped">;
};

export type FolioMessage = UIMessage<FolioMetadata, FolioDataParts>;
