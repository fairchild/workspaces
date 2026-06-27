import {
	type PrReviewRunDetails,
	type PrReviewRunStatus,
	getPrReviewRunByFingerprint,
} from "@/lib/agent-runtime/pr-review-runs";
import { authorizeRepoAccess } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import styles from "./page.module.css";
import { ReviewRunRecoveryAction } from "./review-run-recovery-action";
import { ReviewRunTranscript } from "./review-run-transcript";

export const dynamic = "force-dynamic";

type StepState = "done" | "current" | "pending" | "blocked" | "skipped";

interface LifecycleStep {
	key: string;
	label: string;
	description: string;
	state: StepState;
	time: string | null;
}

function formatDateTime(value: string | null): string {
	if (!value) return "Not recorded";
	return new Date(value).toLocaleString();
}

function formatDuration(startValue: string, endValue: string | null): string {
	const start = new Date(startValue).getTime();
	const end = endValue ? new Date(endValue).getTime() : Date.now();
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

function shortSha(value: string | null): string {
	return value ? value.slice(0, 12) : "unknown";
}

function titleCaseStatus(value: string): string {
	return value
		.split("_")
		.map((part) => part.charAt(0).toUpperCase() + part.slice(1))
		.join(" ");
}

function phaseForRun(run: PrReviewRunDetails): {
	label: string;
	description: string;
	tone: PrReviewRunStatus | "projection-failed";
} {
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

function lifecycleForRun(run: PrReviewRunDetails): LifecycleStep[] {
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

function projectionTypeLabel(value: string): string {
	if (value === "github_status") return "Commit status";
	if (value === "github_review") return "PR review";
	return titleCaseStatus(value);
}

export default async function ReviewRunPage({
	params,
}: {
	params: Promise<{ fingerprint: string }>;
}) {
	const session = await getSession();
	if (!session?.user) redirect("/sign-in");

	const { fingerprint } = await params;
	const run = await getPrReviewRunByFingerprint(fingerprint);
	if (!run) notFound();

	const unauthorized = await authorizeRepoAccess(
		session.user.id,
		run.repoFullName,
	);
	if (unauthorized) notFound();

	const [owner, repo] = run.repoFullName.split("/");
	const prUrl = `https://github.com/${run.repoFullName}/pull/${run.prNumber}`;
	const commitUrl = `https://github.com/${run.repoFullName}/commit/${run.headSha}`;
	const latestCommitUrl = `https://github.com/${run.repoFullName}/commit/${run.latestKnownHeadSha}`;
	const dashboardUrl =
		owner && repo
			? `/dashboard/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}?tab=terminal&agent=pr-reviewer`
			: "/dashboard";
	const projectionError =
		run.projectionError && run.projectionError !== run.error
			? run.projectionError
			: null;
	const phase = phaseForRun(run);
	const lifecycle = lifecycleForRun(run);
	const statusClass = styles[`status-${phase.tone}`] ?? "";
	const endTime =
		run.status === "started" || run.projectionStatus === "pending"
			? null
			: (run.projectionUpdatedAt ?? run.updatedAt);
	const elapsed = formatDuration(run.createdAt, endTime);
	const headChanged = run.latestKnownHeadSha !== run.headSha;
	const lastProjectionAttempt = run.projections
		.map((projection) => projection.lastAttemptedAt)
		.filter((value): value is string => Boolean(value))
		.sort()
		.at(-1);

	return (
		<main className={styles.page}>
			<section className={styles.hero} aria-labelledby="review-run-title">
				<div className={styles.heroMain}>
					<p className={styles.eyebrow}>Managed PR Review</p>
					<div className={styles.titleRow}>
						<h1 id="review-run-title">
							{run.repoFullName}#{run.prNumber}
						</h1>
						<span className={`${styles.status} ${statusClass}`}>
							{phase.label}
						</span>
					</div>
					<p className={styles.phaseDescription}>{phase.description}</p>
					<nav className={styles.links} aria-label="Run links">
						<Link href={prUrl}>Open PR</Link>
						<Link href={commitUrl}>Target commit</Link>
						{headChanged && (
							<Link href={latestCommitUrl}>Latest known commit</Link>
						)}
						<Link href={dashboardUrl}>Terminal tab</Link>
					</nav>
				</div>
				<div className={styles.heroStats} aria-label="Run summary">
					<div>
						<span>Elapsed</span>
						<strong>{elapsed}</strong>
					</div>
					<div>
						<span>Execution</span>
						<strong>{titleCaseStatus(run.executionState)}</strong>
					</div>
					<div>
						<span>GitHub output</span>
						<strong>{titleCaseStatus(run.projectionStatus)}</strong>
					</div>
				</div>
			</section>

			<section
				className={styles.lifecyclePanel}
				aria-labelledby="lifecycle-title"
			>
				<div className={styles.sectionHeader}>
					<div>
						<p className={styles.eyebrow}>Lifecycle</p>
						<h2 id="lifecycle-title">Where this run is going</h2>
					</div>
					<span>
						{run.status} / {run.projectionStatus}
					</span>
				</div>
				<ol className={styles.lifecycle} aria-label="Managed review lifecycle">
					{lifecycle.map((step) => (
						<li
							className={`${styles.lifecycleStep} ${styles[`step-${step.state}`]}`}
							key={step.key}
							aria-current={step.state === "current" ? "step" : undefined}
						>
							<span className={styles.stepMarker} aria-hidden="true" />
							<div>
								<strong>{step.label}</strong>
								<span>{step.description}</span>
								<small>{formatDateTime(step.time)}</small>
							</div>
						</li>
					))}
				</ol>
			</section>

			<div className={styles.contentGrid}>
				<section className={styles.currentPanel}>
					<p className={styles.eyebrow}>Current phase</p>
					<h2>{phase.label}</h2>
					<p>{phase.description}</p>
					<div className={styles.nextAction}>
						<span>Next</span>
						<strong>{run.nextAction}</strong>
						{run.failedAt && (
							<small>Failure recorded {formatDateTime(run.failedAt)}</small>
						)}
					</div>
					<ReviewRunRecoveryAction
						fingerprint={run.fingerprint}
						recovery={run.recovery}
					/>
				</section>

				<section className={styles.trajectoryPanel}>
					<p className={styles.eyebrow}>Trajectory</p>
					<h2>Run path</h2>
					<div className={styles.trajectoryList}>
						<div>
							<span>Created</span>
							<strong>{formatDateTime(run.createdAt)}</strong>
						</div>
						<div>
							<span>Picked up</span>
							<strong>{formatDateTime(run.sessionStartedAt)}</strong>
						</div>
						<div>
							<span>Last updated</span>
							<strong>{formatDateTime(run.updatedAt)}</strong>
						</div>
						<div>
							<span>Target head</span>
							<strong>{shortSha(run.headSha)}</strong>
						</div>
						<div className={headChanged ? styles.changedMetric : undefined}>
							<span>Latest known head</span>
							<strong>{shortSha(run.latestKnownHeadSha)}</strong>
						</div>
						{run.coalescedAt && (
							<div className={styles.changedMetric}>
								<span>Coalesced trigger</span>
								<strong>
									{titleCaseStatus(run.coalescedTriggerKind ?? "trigger")} at{" "}
									{formatDateTime(run.coalescedAt)}
								</strong>
							</div>
						)}
					</div>
				</section>
			</div>

			{run.failureMessage && (
				<pre className={styles.errorBlock}>{run.failureMessage}</pre>
			)}
			{projectionError && (
				<pre className={styles.errorBlock}>{projectionError}</pre>
			)}

			<section className={styles.projections}>
				<div className={styles.sectionHeader}>
					<div>
						<p className={styles.eyebrow}>GitHub output</p>
						<h2>Projection ledger</h2>
					</div>
					<span>
						{run.projections.length} record
						{run.projections.length === 1 ? "" : "s"}
					</span>
				</div>
				<div className={styles.projectionSummary}>
					<div>
						<span>Status</span>
						<strong>{titleCaseStatus(run.projectionStatus)}</strong>
					</div>
					<div>
						<span>Last attempt</span>
						<strong>{formatDateTime(lastProjectionAttempt ?? null)}</strong>
					</div>
					<div>
						<span>GitHub review</span>
						<strong>{run.githubReviewId ?? "Not posted"}</strong>
					</div>
				</div>
				{run.projections.length === 0 ? (
					<p className={styles.muted}>No projection records yet.</p>
				) : (
					<div className={styles.projectionList}>
						{run.projections.map((projection) => (
							<div
								className={styles.projectionRow}
								key={projection.projectionId}
							>
								<div>
									<strong>{projectionTypeLabel(projection.type)}</strong>
									<span>{projection.projectionKey}</span>
								</div>
								<div>
									<span>State</span>
									<strong>{titleCaseStatus(projection.state)}</strong>
								</div>
								<div>
									<span>Attempts</span>
									<strong>{projection.attempts}</strong>
								</div>
								<div>
									<span>Last attempt</span>
									<strong>{formatDateTime(projection.lastAttemptedAt)}</strong>
								</div>
								<div>
									<span>Desired hash</span>
									<strong>{projection.desiredPayloadHash.slice(0, 16)}</strong>
								</div>
								{projection.observedExternalId && (
									<div>
										<span>External ID</span>
										<strong>{projection.observedExternalId}</strong>
									</div>
								)}
								{projection.errorKind && (
									<div>
										<span>Error</span>
										<strong>{projection.errorKind}</strong>
									</div>
								)}
								{projection.errorText && (
									<pre className={styles.projectionError}>
										{projection.errorText}
									</pre>
								)}
							</div>
						))}
					</div>
				)}
			</section>

			<details className={styles.operatorDetails}>
				<summary>Operator details</summary>
				<div className={styles.detailGrid}>
					<div>
						<span>Run fingerprint</span>
						<strong>{run.fingerprint}</strong>
					</div>
					<div>
						<span>Trigger</span>
						<strong>
							{run.triggerKind} / {run.triggerSourceId}
						</strong>
					</div>
					<div>
						<span>Session</span>
						<strong>{run.sessionId ?? "Not assigned"}</strong>
					</div>
					<div>
						<span>Reviewer config</span>
						<strong>{run.reviewerConfigHash}</strong>
					</div>
					{run.failureKind && (
						<div>
							<span>Failure kind</span>
							<strong>{run.failureKind}</strong>
						</div>
					)}
					{run.failureRetryable !== null && (
						<div>
							<span>Retryable</span>
							<strong>{run.failureRetryable ? "Yes" : "No"}</strong>
						</div>
					)}
				</div>
			</details>

			<ReviewRunTranscript
				fingerprint={run.fingerprint}
				initialSessionId={run.sessionId}
				initialStatus={run.status}
				initialError={run.error}
			/>
		</main>
	);
}
