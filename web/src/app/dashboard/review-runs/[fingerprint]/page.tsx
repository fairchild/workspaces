import { getPrReviewRunByFingerprint } from "@/lib/agent-runtime/pr-review-runs";
import { authorizeRepoAccess } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { ElapsedDuration } from "./elapsed-duration";
import styles from "./page.module.css";
import {
	lifecycleForRun,
	phaseForRun,
	titleCaseStatus,
} from "./review-run-detail-view-model";
import { ReviewRunRecoveryAction } from "./review-run-recovery-action";
import { ReviewRunTranscript } from "./review-run-transcript";

export const dynamic = "force-dynamic";

function formatDateTime(value: string | null): string {
	if (!value) return "Not recorded";
	return new Date(value).toLocaleString();
}

function shortSha(value: string | null): string {
	return value ? value.slice(0, 12) : "unknown";
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
	const renderNow = Date.now();
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
						<strong>
							<ElapsedDuration
								startValue={run.createdAt}
								endValue={endTime}
								initialNow={renderNow}
							/>
						</strong>
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
					<p className={styles.eyebrow}>Operator focus</p>
					<h2>{phase.label}</h2>
					<div className={styles.nextAction}>
						<span>Next action</span>
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
