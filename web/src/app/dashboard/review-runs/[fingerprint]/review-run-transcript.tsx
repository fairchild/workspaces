"use client";

import { useEffect, useState } from "react";
import { TranscriptTerminal } from "../../components/transcript-terminal";
import styles from "./page.module.css";

interface ReviewRunTranscriptProps {
	fingerprint: string;
	initialSessionId: string | null;
	initialStatus: string;
	initialError: string | null;
}

interface ReviewRunResponse {
	run?: {
		sessionId: string | null;
		status: string;
		error: string | null;
	};
}

export function ReviewRunTranscript({
	fingerprint,
	initialSessionId,
	initialStatus,
	initialError,
}: ReviewRunTranscriptProps) {
	const [sessionId, setSessionId] = useState(initialSessionId);
	const [status, setStatus] = useState(initialStatus);
	const [error, setError] = useState(initialError);

	useEffect(() => {
		if (sessionId) return;

		const poll = async () => {
			const response = await fetch(
				`/api/pr-review-runs/${encodeURIComponent(fingerprint)}`,
			);
			if (!response.ok) return;
			const data = (await response.json()) as ReviewRunResponse;
			if (!data.run) return;
			setSessionId(data.run.sessionId);
			setStatus(data.run.status);
			setError(data.run.error);
		};

		void poll();
		const interval = window.setInterval(() => void poll(), 2500);
		return () => window.clearInterval(interval);
	}, [fingerprint, sessionId]);

	if (!sessionId) {
		return (
			<section className={styles.transcriptCard}>
				<h2>Transcript</h2>
				<p className={styles.muted}>
					Managed review status: <strong>{status}</strong>
				</p>
				{error ? (
					<pre className={styles.errorBlock}>{error}</pre>
				) : (
					<p className={styles.muted}>
						Waiting for the managed-agent session id.
					</p>
				)}
			</section>
		);
	}

	return (
		<section className={styles.transcriptCard}>
			<div className={styles.transcriptHeader}>
				<h2>Transcript</h2>
				<span className={styles.sessionId}>{sessionId}</span>
			</div>
			<div className={styles.transcriptFrame}>
				<TranscriptTerminal
					sessionId={sessionId}
					agentName="pr-reviewer"
					active={true}
				/>
			</div>
		</section>
	);
}
