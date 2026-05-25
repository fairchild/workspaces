import { getPrReviewRunByFingerprint } from "@/lib/agent-runtime/pr-review-runs";
import { authorizeRepoAccess } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";
import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import styles from "./page.module.css";
import { ReviewRunTranscript } from "./review-run-transcript";

export const dynamic = "force-dynamic";

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
	const dashboardUrl =
		owner && repo
			? `/dashboard/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}?tab=terminal&agent=pr-reviewer`
			: "/dashboard";
	const statusClass = styles[`status-${run.status}`] ?? "";
	const projectionError =
		run.projectionError && run.projectionError !== run.error
			? run.projectionError
			: null;

	return (
		<main className={styles.page}>
			<div className={styles.header}>
				<div>
					<p className={styles.eyebrow}>Managed PR Review</p>
					<h1>
						{run.repoFullName}#{run.prNumber}
					</h1>
				</div>
				<span className={`${styles.status} ${statusClass}`}>
					{run.status} / {run.projectionStatus}
				</span>
			</div>

			<section className={styles.summary}>
				<div>
					<span>Run</span>
					<strong>{run.fingerprint}</strong>
				</div>
				<div>
					<span>Trigger</span>
					<strong>
						{run.triggerKind} / {run.triggerSourceId}
					</strong>
				</div>
				<div>
					<span>Head</span>
					<strong>{run.headSha.slice(0, 12)}</strong>
				</div>
				<div>
					<span>Updated</span>
					<strong>{new Date(run.updatedAt).toLocaleString()}</strong>
				</div>
				<div>
					<span>Projection</span>
					<strong>
						{run.projectionStatus} /{" "}
						{new Date(run.projectionUpdatedAt).toLocaleString()}
					</strong>
				</div>
				{run.githubReviewId && (
					<div>
						<span>GitHub review</span>
						<strong>{run.githubReviewId}</strong>
					</div>
				)}
			</section>

			<nav className={styles.links} aria-label="Run links">
				<Link href={prUrl}>Open PR</Link>
				<Link href={commitUrl}>Open commit</Link>
				<Link href={dashboardUrl}>Open terminal tab</Link>
			</nav>

			{run.error && <pre className={styles.errorBlock}>{run.error}</pre>}
			{projectionError && (
				<pre className={styles.errorBlock}>{projectionError}</pre>
			)}

			<ReviewRunTranscript
				fingerprint={run.fingerprint}
				initialSessionId={run.sessionId}
				initialStatus={run.status}
				initialError={run.error}
			/>
		</main>
	);
}
