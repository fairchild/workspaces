"use client";

/*
 * Transcript approval affordance: a pending permission request is a quiet
 * inline card with Allow/Deny, and the resolved state is a one-line receipt.
 * It renders from durable data-approval parts, so reloads and live streams
 * share the same view.
 */
import { useEffect, useState } from "react";
import type {
	ApprovalDecision,
	ApprovalResolvedBy,
} from "@/lib/agent-runtime/stream-chunk";
import type { ApprovalPartData } from "./types";

export interface ApprovalCardProps {
	approval: ApprovalPartData;
	onDecision?: (requestId: string, decision: ApprovalDecision) => Promise<void>;
}

function countdownLabel(ms: number): string {
	if (ms <= 0) return "expired";
	const seconds = Math.ceil(ms / 1000);
	if (seconds < 60) return `${seconds}s left`;
	return `${Math.ceil(seconds / 60)}m left`;
}

function decisionLabel(decision: ApprovalDecision): string {
	return decision === "allow" ? "allowed" : "denied";
}

function receiptActor(resolvedBy: ApprovalResolvedBy): string {
	if (resolvedBy === "user") return "you";
	if (resolvedBy === "timeout") return "timeout";
	return "turn stop";
}

export function ApprovalCard({ approval, onDecision }: ApprovalCardProps) {
	const [now, setNow] = useState(() => Date.now());
	const [submitting, setSubmitting] = useState<ApprovalDecision | null>(null);
	const [error, setError] = useState<string | null>(null);

	useEffect(() => {
		if (approval.state !== "pending") return;
		const timer = setInterval(() => setNow(Date.now()), 1000);
		return () => clearInterval(timer);
	}, [approval.state]);

	if (approval.state === "resolved") {
		return (
			<div
				data-testid="approval-receipt"
				className="my-5 font-mono text-stat tracking-[.04em] text-hint"
			>
				{approval.toolName} approval {decisionLabel(approval.decision)} by{" "}
				{receiptActor(approval.resolvedBy)}.
			</div>
		);
	}

	const remaining = Date.parse(approval.expiresAt) - now;
	const expired = remaining <= 0;
	const disabled = expired || submitting !== null || onDecision === undefined;

	const submit = async (decision: ApprovalDecision) => {
		if (disabled || !onDecision) return;
		setSubmitting(decision);
		setError(null);
		try {
			await onDecision(approval.requestId, decision);
		} catch (caught) {
			setSubmitting(null);
			setError(caught instanceof Error ? caught.message : "approval failed");
		}
	};

	return (
		<div
			data-testid="approval-card"
			className="my-5 rounded-lg border border-line bg-raised px-4 py-3 shadow-[0_10px_28px_rgba(0,0,0,.04)]"
		>
			<div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
				<span className="font-mono text-label font-medium tracking-[.16em] text-hint uppercase">
					Approval
				</span>
				<span className="font-mono text-caption text-muted">
					{approval.toolName}
				</span>
				<span className="ml-auto font-mono text-caption text-hint">
					{countdownLabel(remaining)}
				</span>
			</div>
			<p className="mt-3 text-body text-ink">{approval.summary}</p>
			<p className="mt-2 font-mono text-code whitespace-pre-wrap text-muted">
				{approval.inputSummary}
			</p>
			<div className="mt-4 flex flex-wrap items-center gap-2.5">
				<button
					type="button"
					onClick={() => void submit("allow")}
					disabled={disabled}
					className="rounded-md border border-line-strong px-3 py-1.5 font-mono text-caption text-ink transition-colors duration-200 hover:bg-paper disabled:cursor-default disabled:opacity-50 disabled:hover:bg-transparent"
				>
					{submitting === "allow" ? "Allowing" : "Allow"}
				</button>
				<button
					type="button"
					onClick={() => void submit("deny")}
					disabled={disabled}
					className="rounded-md border border-line px-3 py-1.5 font-mono text-caption text-muted transition-colors duration-200 hover:text-del-ink disabled:cursor-default disabled:opacity-50 disabled:hover:text-muted"
				>
					{submitting === "deny" ? "Denying" : "Deny"}
				</button>
				{error && (
					<span className="font-mono text-caption text-del-ink">{error}</span>
				)}
			</div>
		</div>
	);
}
