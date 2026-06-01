"use client";

import type { PrReviewRunRecoveryAvailability } from "@/lib/agent-runtime/pr-review-runs";
import { useRouter } from "next/navigation";
import { useState } from "react";
import styles from "./page.module.css";

interface ReviewRunRecoveryActionProps {
	fingerprint: string;
	recovery: PrReviewRunRecoveryAvailability;
}

interface RecoveryResponse {
	ok?: boolean;
	message?: string;
	error?: string;
	outcome?: string;
}

export function ReviewRunRecoveryAction({
	fingerprint,
	recovery,
}: ReviewRunRecoveryActionProps) {
	const router = useRouter();
	const [pending, setPending] = useState(false);
	const [result, setResult] = useState<string | null>(null);

	const recover = async () => {
		setPending(true);
		setResult(null);
		try {
			const response = await fetch(
				`/api/pr-review-runs/${encodeURIComponent(fingerprint)}`,
				{ method: "POST" },
			);
			const data = (await response
				.json()
				.catch(() => ({}))) as RecoveryResponse;
			if (!response.ok || data.ok === false) {
				setResult(data.error ?? `Recovery failed (${response.status}).`);
				return;
			}
			setResult(data.message ?? data.outcome ?? "Recovery request accepted.");
			router.refresh();
		} finally {
			setPending(false);
		}
	};

	return (
		<div className={styles.recoveryAction}>
			<span>Recovery</span>
			<strong>{recovery.reason}</strong>
			{recovery.available && recovery.label ? (
				<button type="button" onClick={recover} disabled={pending}>
					{pending ? "Working..." : recovery.label}
				</button>
			) : (
				<small>Unavailable</small>
			)}
			{result && <small>{result}</small>}
		</div>
	);
}
