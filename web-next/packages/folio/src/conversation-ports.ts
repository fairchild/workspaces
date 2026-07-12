/*
 * Host-neutral conversation authority for Folio. Hosts own persistence,
 * transport, compute, workspaces, and publication; Folio consumes snapshots,
 * ordered events, and explicitly available commands through this membrane.
 */
import type { ActiveTurnData, QueuedMessageData, SessionViewData } from "./session-view";
import type { ApprovalDecision } from "./types";

/** Opaque durable resume token; hosts persist it across reload and restart. */
export type FolioConversationCursor = string;

export class FolioCapabilityUnavailableError extends Error {}

/** The host cannot resume from a cursor it did not issue or no longer retains. */
export class FolioUnknownCursorError extends Error {}

export interface FolioConversationCapabilities {
	send: boolean;
	stop: boolean;
	retry: boolean;
	cancelQueuedMessage: boolean;
	decideApproval: boolean;
	decideReview: boolean;
	updateConversation: boolean;
}

export interface FolioArtifact {
	id: string;
	kind: "diff" | "file" | "report" | "link";
	label: string;
	url?: string;
}

export interface FolioReview {
	id: string;
	summary: string;
	changedFiles: readonly string[];
	state: "pending" | "accepted" | "rejected";
}

export interface FolioWorkspace {
	id: string;
	label?: string;
	state: string;
	actions: readonly string[];
}

export interface FolioPublication {
	id: string | null;
	state: string | null;
	url: string | null;
	actions: readonly string[];
}

export interface FolioConversationSnapshot {
	conversationId: string;
	cursor: FolioConversationCursor;
	view: SessionViewData;
	queuedMessages: QueuedMessageData[];
	capabilities: FolioConversationCapabilities;
	artifacts: FolioArtifact[];
	review: FolioReview | null;
	workspace: FolioWorkspace | null;
	publication: FolioPublication | null;
	failure: string | null;
}

interface EventEnvelope {
	cursor: FolioConversationCursor;
}

export type FolioConversationEvent =
	| (EventEnvelope & { type: "message-upsert"; message: SessionViewData["messages"][number] })
	| (EventEnvelope & { type: "active-turn"; activeTurn: ActiveTurnData | null })
	| (EventEnvelope & { type: "queued-messages"; messages: QueuedMessageData[] })
	| (EventEnvelope & {
			type: "conversation-updated";
			title?: string;
			model?: string;
			modelLabel?: string;
	  })
	| (EventEnvelope & { type: "capabilities"; capabilities: FolioConversationCapabilities })
	| (EventEnvelope & { type: "status"; status: SessionViewData["statusLine"] })
	| (EventEnvelope & { type: "artifact"; artifact: FolioArtifact })
	| (EventEnvelope & { type: "review"; review: FolioReview | null })
	| (EventEnvelope & { type: "workspace"; workspace: FolioWorkspace | null })
	| (EventEnvelope & { type: "publication"; publication: FolioPublication | null })
	| (EventEnvelope & { type: "failure"; message: string })
	| (EventEnvelope & { type: "complete" });

export interface FolioCommandReceipt {
	/**
	 * A host cursor known to contain the command's effect. `null` means the host
	 * accepted the command but its externally owned projection has not observed
	 * the effect yet; callers must await the next snapshot rather than assuming.
	 */
	cursor: FolioConversationCursor | null;
}

export interface FolioSendRequest {
	text: string;
	/** Unique client correlation id. Hosts may additionally use it for deduplication. */
	requestId: string;
	/** UI provenance only; a retry remains a new send unless the host says otherwise. */
	retryOf?: string;
}

/** One atomic mutable field per command; hosts never expose partial combined updates. */
export type FolioConversationUpdate =
	| { title: string; model?: never }
	| { model: string; title?: never };

export interface FolioConversationPort {
	readSnapshot(signal?: AbortSignal): Promise<FolioConversationSnapshot>;
	readEvents(
		after: FolioConversationCursor,
		signal?: AbortSignal,
	): AsyncIterable<FolioConversationEvent>;
	send(request: FolioSendRequest, signal?: AbortSignal): Promise<FolioCommandReceipt>;
	stop(signal?: AbortSignal): Promise<FolioCommandReceipt>;
	cancelQueuedMessage(queueId: string, signal?: AbortSignal): Promise<FolioCommandReceipt>;
	decideApproval(
		requestId: string,
		decision: ApprovalDecision,
		signal?: AbortSignal,
	): Promise<FolioCommandReceipt>;
	decideReview(
		decision: "accept" | "reject",
		note?: string,
		signal?: AbortSignal,
	): Promise<FolioCommandReceipt>;
	updateConversation(
		update: FolioConversationUpdate,
		signal?: AbortSignal,
	): Promise<FolioCommandReceipt>;
	requestWorkspaceAction(
		action: string,
		signal?: AbortSignal,
	): Promise<FolioCommandReceipt>;
	requestPublication(
		action: string,
		signal?: AbortSignal,
	): Promise<FolioCommandReceipt>;
}

/** UI-level dependency injection. An absent callback is an absent capability. */
export interface FolioConversationActions {
	send?: (text: string) => void;
	retry?: (messageId: string, text: string) => void;
	cancelQueuedMessage?: (queueId: string) => void;
	changeModel?: (id: string) => void;
	changeTitle?: (title: string) => void;
	stopTurn?: () => void;
	stopWorkspace?: () => void;
	requestPublication?: (action?: string) => void;
	decideApproval?: (
		requestId: string,
		decision: ApprovalDecision,
	) => Promise<void>;
}
