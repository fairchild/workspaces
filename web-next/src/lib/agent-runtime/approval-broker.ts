/*
 * Durable approval rendezvous for provider turns. Providers create a request
 * row, emit the matching approval_request chunk through the normal ingest log,
 * then await this broker. The answer endpoint only updates turn_approvals and
 * wakes waiters; it never appends transcript events, keeping session_events
 * single-writer.
 */
import { EventEmitter } from "node:events";
import type { DatabaseHandle, TurnApprovalsTable } from "../db/client";
import { ensureSchema } from "../db/schema";
import type {
	ApprovalDecision,
	ApprovalResolvedBy,
	ApprovalRequestMetadata,
} from "./stream-chunk";

export interface ApprovalResolution {
	requestId: string;
	decision: ApprovalDecision;
	resolvedBy: ApprovalResolvedBy;
	decidedAt: string;
}

export interface ApprovalRequestInput {
	sessionId: string;
	toolName: string;
	inputSummary: string;
	timeoutMs: number;
	requestId?: string;
	requestedAt?: string;
	expiresAt?: string;
	signal?: AbortSignal;
	/** Test seam; production uses the default low polling cadence. */
	pollIntervalMs?: number;
}

export interface PendingApprovalRequest extends ApprovalRequestMetadata {
	requestedAt: string;
	resolution: Promise<ApprovalResolution>;
}

export type ApprovalAnswerResult =
	| { status: "resolved"; resolution: ApprovalResolution }
	| { status: "unknown" }
	| { status: "already-decided"; resolution: ApprovalResolution }
	| { status: "expired" };

const DEFAULT_POLL_INTERVAL_MS = 500;

const bus = new EventEmitter();
bus.setMaxListeners(0);

function approvalKey(sessionId: string, requestId: string): string {
	return `${sessionId}:${requestId}`;
}

function notifyApproval(sessionId: string, requestId: string): void {
	bus.emit(approvalKey(sessionId, requestId));
}

function nowIso(): string {
	return new Date().toISOString();
}

function rowResolution(row: TurnApprovalsTable): ApprovalResolution | undefined {
	if (!row.decision || !row.decided_by || !row.decided_at) return undefined;
	return {
		requestId: row.request_id,
		decision: row.decision,
		resolvedBy: row.decided_by,
		decidedAt: row.decided_at,
	};
}

export async function getApprovalRequest(
	handle: DatabaseHandle,
	sessionId: string,
	requestId: string,
): Promise<TurnApprovalsTable | undefined> {
	await ensureSchema(handle);
	return handle.db
		.selectFrom("turn_approvals")
		.selectAll()
		.where("session_id", "=", sessionId)
		.where("request_id", "=", requestId)
		.executeTakeFirst();
}

/**
 * Inserts the request row and starts waiting for its answer. Callers emit the
 * approval_request chunk only after this resolves, so a visible card always has
 * a durable row for the answer endpoint to update.
 */
export async function beginApprovalRequest(
	handle: DatabaseHandle,
	input: ApprovalRequestInput,
): Promise<PendingApprovalRequest> {
	await ensureSchema(handle);
	const requestedAt = input.requestedAt ?? nowIso();
	const expiresAt =
		input.expiresAt ??
		new Date(Date.parse(requestedAt) + input.timeoutMs).toISOString();
	const requestId = input.requestId ?? crypto.randomUUID();
	await handle.db
		.insertInto("turn_approvals")
		.values({
			session_id: input.sessionId,
			request_id: requestId,
			tool_name: input.toolName,
			input_summary: input.inputSummary,
			requested_at: requestedAt,
			expires_at: expiresAt,
			decision: null,
			decided_at: null,
			decided_by: null,
		})
		.execute();

	const resolution = waitForApproval(handle, {
		sessionId: input.sessionId,
		requestId,
		expiresAt,
		signal: input.signal,
		pollIntervalMs: input.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS,
	});
	return {
		requestId,
		toolName: input.toolName,
		inputSummary: input.inputSummary,
		requestedAt,
		expiresAt,
		resolution,
	};
}

/** Broker API for callers that only need the final verdict. */
export async function requestApproval(
	handle: DatabaseHandle,
	input: ApprovalRequestInput,
): Promise<ApprovalResolution> {
	const pending = await beginApprovalRequest(handle, input);
	return pending.resolution;
}

async function waitForApproval(
	handle: DatabaseHandle,
	input: {
		sessionId: string;
		requestId: string;
		expiresAt: string;
		signal?: AbortSignal;
		pollIntervalMs: number;
	},
): Promise<ApprovalResolution> {
	const expiryMs = Date.parse(input.expiresAt);
	while (true) {
		const row = await getApprovalRequest(handle, input.sessionId, input.requestId);
		const resolved = row ? rowResolution(row) : undefined;
		if (resolved) return resolved;

		if (input.signal?.aborted) {
			return resolveApprovalBySystem(handle, {
				sessionId: input.sessionId,
				requestId: input.requestId,
				resolvedBy: "abort",
			});
		}
		const remainingMs = expiryMs - Date.now();
		if (remainingMs <= 0) {
			return resolveApprovalBySystem(handle, {
				sessionId: input.sessionId,
				requestId: input.requestId,
				resolvedBy: "timeout",
			});
		}
		await waitForWakeup(
			input.sessionId,
			input.requestId,
			Math.min(input.pollIntervalMs, remainingMs),
			input.signal,
		);
	}
}

function waitForWakeup(
	sessionId: string,
	requestId: string,
	timeoutMs: number,
	signal?: AbortSignal,
): Promise<void> {
	return new Promise((resolve) => {
		const key = approvalKey(sessionId, requestId);
		const cleanup = () => {
			clearTimeout(timeout);
			bus.off(key, onWakeup);
			signal?.removeEventListener("abort", onWakeup);
		};
		const onWakeup = () => {
			cleanup();
			resolve();
		};
		bus.once(key, onWakeup);
		signal?.addEventListener("abort", onWakeup, { once: true });
		const timeout = setTimeout(onWakeup, Math.max(1, timeoutMs));
	});
}

export async function answerApproval(
	handle: DatabaseHandle,
	input: {
		sessionId: string;
		requestId: string;
		decision: ApprovalDecision;
		now?: string;
	},
): Promise<ApprovalAnswerResult> {
	await ensureSchema(handle);
	const row = await getApprovalRequest(handle, input.sessionId, input.requestId);
	if (!row) return { status: "unknown" };
	const existing = rowResolution(row);
	if (existing) return { status: "already-decided", resolution: existing };

	const decidedAt = input.now ?? nowIso();
	if (Date.parse(row.expires_at) <= Date.parse(decidedAt)) {
		return { status: "expired" };
	}

	const result = await handle.db
		.updateTable("turn_approvals")
		.set({
			decision: input.decision,
			decided_at: decidedAt,
			decided_by: "user",
		})
		.where("session_id", "=", input.sessionId)
		.where("request_id", "=", input.requestId)
		.where("decision", "is", null)
		.where("expires_at", ">", decidedAt)
		.execute();
	if (Number(result[0]?.numUpdatedRows ?? 0) === 0) {
		const latest = await getApprovalRequest(handle, input.sessionId, input.requestId);
		const latestResolution = latest ? rowResolution(latest) : undefined;
		if (latestResolution)
			return { status: "already-decided", resolution: latestResolution };
		return { status: "expired" };
	}

	notifyApproval(input.sessionId, input.requestId);
	return {
		status: "resolved",
		resolution: {
			requestId: input.requestId,
			decision: input.decision,
			resolvedBy: "user",
			decidedAt,
		},
	};
}

async function resolveApprovalBySystem(
	handle: DatabaseHandle,
	input: {
		sessionId: string;
		requestId: string;
		resolvedBy: Exclude<ApprovalResolvedBy, "user">;
	},
): Promise<ApprovalResolution> {
	const decidedAt = nowIso();
	await handle.db
		.updateTable("turn_approvals")
		.set({
			decision: "deny",
			decided_at: decidedAt,
			decided_by: input.resolvedBy,
		})
		.where("session_id", "=", input.sessionId)
		.where("request_id", "=", input.requestId)
		.where("decision", "is", null)
		.execute();
	notifyApproval(input.sessionId, input.requestId);

	const row = await getApprovalRequest(handle, input.sessionId, input.requestId);
	const resolved = row ? rowResolution(row) : undefined;
	return (
		resolved ?? {
			requestId: input.requestId,
			decision: "deny",
			resolvedBy: input.resolvedBy,
			decidedAt,
		}
	);
}
