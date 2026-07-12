/**
 * Folio's public package surface. Hosts supply conversation data and actions;
 * Folio owns the calm transcript, compose, and status presentation. Theme and
 * pure-format helpers have narrow entries so hosts do not load this UI graph.
 */
export {
	SessionView,
	type ActiveTurnData,
	type EmptyTranscriptNote,
	type QueuedMessageData,
	type SessionViewData,
	type SessionViewProps,
} from "./session-view";
export type { MastheadData } from "./session-masthead";
export type {
	ApprovalDecision,
	ApprovalPartData,
	ApprovalResolvedBy,
	ConfigReceipt,
	ConfigReceiptFile,
	DiffCardData,
	DiffLine,
	FolioDataParts,
	FolioMessage,
	FolioMetadata,
	SkippedConfigReceiptFile,
	TurnStatsData,
} from "./types";
