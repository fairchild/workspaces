import type {
	PrReviewRunDetails,
	PrReviewRunStatus,
} from "@/lib/agent-runtime/pr-review-runs";

export type StepState = "done" | "current" | "pending" | "blocked" | "skipped";

export interface LifecycleStep {
	key: string;
	label: string;
	description: string;
	state: StepState;
	time: string | null;
}

export interface ReviewRunPhase {
	label: string;
	description: string;
	tone: PrReviewRunStatus | "projection-failed";
}

export function formatDuration(
	startValue: string,
	endValue: string | null,
	now = Date.now(),
): string {
	const start = new Date(startValue).getTime();
	const end = endValue ? new Date(endValue).getTime() : now;
	if (!Number.isFinite(start) || !Number.isFinite(end) || end < start) {
		return "Unknown";
	}
	const totalSeconds = Math.max(0, Math.round((end - start) / 1000));
	const hours = Math.floor(totalSeconds / 3600);
	const minutes = Math.floor((totalSeconds % 3600) / 60);
	const seconds = totalSeconds % 60;
	if (hours > 0) return `${hours}h ${minutes}m`;
	if (minutes > 0) return `${minutes}m ${seconds}s`;
	return `${seconds}s`;
}

export function titleCaseStatus(value: string): string {
	return value
		.split("_")
		.map((part) => part.charAt(0).toUpperCase() + part.slice(1))
		.join(" ");
}

export function phaseForRun(run: PrReviewRunDetails): ReviewRunPhase {
	if (run.status === "superseded") {
		return {
			label: "Superseded",
			description:
				"A newer managed-review trigger took over for this pull request.",
			tone: "superseded",
		};
	}
	if (run.status === "failed") {
		return {
			label: "Execution failed",
			description:
				run.failureMessage ??
				"The reviewer run failed before it could produce a GitHub result.",
			tone: "failed",
		};
	}
	if (run.projectionStatus === "failed") {
		return {
			label: "GitHub output needs repair",
			description:
				run.projectionError ??
				"The agent finished, but WorkSpaces could not publish the result to GitHub.",
			tone: "projection-failed",
		};
	}
	if (run.status === "completed" && run.projectionStatus === "projected") {
		return {
			label: "Published to GitHub",
			description:
				"The managed review completed and its status/review projection has been recorded.",
			tone: "completed",
		};
	}
	if (run.status === "completed") {
		return {
			label: "Awaiting GitHub output",
			description:
				"The agent produced review intent; the broker still needs to publish it to GitHub.",
			tone: "completed",
		};
	}
	if (run.sessionId) {
		return {
			label: "Agent running",
			description:
				"The run has been picked up and the managed PR reviewer session is active.",
			tone: "started",
		};
	}
	return {
		label: "Waiting for pickup",
		description:
			"WorkSpaces created the ReviewRun and is waiting for a managed-agent session.",
		tone: "started",
	};
}

export function lifecycleForRun(run: PrReviewRunDetails): LifecycleStep[] {
	const failedBeforePickup = run.status === "failed" && !run.sessionId;
	const projectionBlocked = run.projectionStatus === "failed";
	const published = run.projectionStatus === "projected";
	const superseded = run.status === "superseded";
	const completed = run.status === "completed";
	const failed = run.status === "failed";

	return [
		{
			key: "trigger",
			label: "Trigger",
			description: `${titleCaseStatus(run.triggerKind)} created the ReviewRun.`,
			state: "done",
			time: run.createdAt,
		},
		{
			key: "pickup",
			label: "Pickup",
			description: run.sessionId
				? "Managed-agent session attached."
				: "Waiting for a session id.",
			state: run.sessionId
				? "done"
				: failedBeforePickup
					? "blocked"
					: superseded
						? "skipped"
						: "current",
			time: run.sessionStartedAt,
		},
		{
			key: "agent",
			label: "Agent",
			description:
				failed && run.failureKind
					? titleCaseStatus(run.failureKind)
					: "Reviewer evaluates the PR and prepares review intent.",
			state: failed
				? "blocked"
				: completed || published
					? "done"
					: superseded
						? "skipped"
						: run.sessionId
							? "current"
							: "pending",
			time: run.failedAt ?? (completed || published ? run.updatedAt : null),
		},
		{
			key: "intent",
			label: "Review intent",
			description: run.reviewIntent
				? `${titleCaseStatus(run.reviewIntent.event)} intent recorded.`
				: "No review intent recorded yet.",
			state: run.reviewIntent
				? "done"
				: failed && run.failureKind === "review_intent_invalid"
					? "blocked"
					: superseded
						? "skipped"
						: completed
							? "blocked"
							: "pending",
			time: run.reviewIntent ? run.updatedAt : null,
		},
		{
			key: "github",
			label: "GitHub output",
			description:
				run.projectionStatus === "projected"
					? "Status and review projection published."
					: run.projectionStatus === "failed"
						? "Projection failed and can be repaired when available."
						: "Broker publishes the ReviewRun result to GitHub.",
			state: published
				? "done"
				: projectionBlocked
					? "blocked"
					: completed
						? "current"
						: superseded
							? "skipped"
							: "pending",
			time: run.projectionUpdatedAt,
		},
		{
			key: "outcome",
			label:
				run.status === "superseded"
					? "Superseded"
					: run.recovery.available
						? "Recovery"
						: "Done",
			description: run.recovery.available
				? run.recovery.reason
				: run.nextAction,
			state:
				published || superseded
					? "done"
					: failed || projectionBlocked
						? "current"
						: "pending",
			time: published || superseded ? run.updatedAt : null,
		},
	];
}
