/*
 * The universal streaming unit shared with the legacy web/ agent runtime.
 * Every compute provider (Vercel Sandbox, Anthropic Managed Agents, mock)
 * emits these; the transcript adapter turns them into AI SDK UIMessage chunks.
 */
import type {
	ApprovalDecision,
	ApprovalResolvedBy,
} from "@fairchild/folio";

export type {
	ApprovalDecision,
	ApprovalResolvedBy,
	ConfigReceipt,
	ConfigReceiptFile,
	SkippedConfigReceiptFile,
} from "@fairchild/folio";

export interface ApprovalRequestMetadata {
	requestId: string;
	toolName: string;
	inputSummary: string;
	expiresAt: string;
}

export interface ApprovalResolvedMetadata {
	requestId: string;
	decision: ApprovalDecision;
	resolvedBy: ApprovalResolvedBy;
}

export interface StreamChunk {
	type:
		| "text"
		| "reasoning"
		| "tool_use"
		| "tool_result"
		| "status"
		| "config_receipt"
		| "error"
		| "done"
		| "approval_request"
		| "approval_resolved";
	content: string;
	metadata?: Record<string, unknown>;
}
