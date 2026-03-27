"use client";

import {
	type CIDetail,
	type DiscussionDetail,
	type IssueDetail,
	type PRDetail,
	type PushDetail,
	extractCIDetail,
	extractDiscussionDetail,
	extractIssueDetail,
	extractPRDetail,
	extractPushDetail,
	getSourceUrl,
} from "@/lib/event-source";
import type { WebhookEvent, WebhookEventType } from "@/lib/types";
import { useEffect, useState } from "react";
import styles from "./event-detail.module.css";

interface EventDetailProps {
	eventId: string;
	eventType: WebhookEventType;
}

export function EventDetail({ eventId, eventType }: EventDetailProps) {
	const [event, setEvent] = useState<WebhookEvent | null>(null);
	const [loading, setLoading] = useState(true);

	useEffect(() => {
		let cancelled = false;
		setLoading(true);
		fetch(`/api/events/${eventId}`)
			.then((r) => (r.ok ? r.json() : null))
			.then((data) => {
				if (!cancelled) {
					setEvent(data);
					setLoading(false);
				}
			})
			.catch(() => {
				if (!cancelled) setLoading(false);
			});
		return () => {
			cancelled = true;
		};
	}, [eventId]);

	if (loading) return <div className={styles.skeleton} />;
	if (!event) return null;

	let payload: Record<string, unknown> = {};
	try {
		payload = JSON.parse(event.payload ?? "{}");
	} catch {
		/* invalid payload */
	}

	const isEmpty = Object.keys(payload).length === 0;
	const sourceUrl = isEmpty ? null : getSourceUrl(eventType, payload);

	if (isEmpty) {
		return (
			<div className={styles.detail}>
				<span className={styles.fallback}>
					Full details not available for this event
				</span>
			</div>
		);
	}

	return (
		<div className={styles.detail}>
			<TypeContent type={eventType} payload={payload} />
			{sourceUrl && (
				<a
					href={sourceUrl}
					target="_blank"
					rel="noopener noreferrer"
					className={styles.sourceLink}
				>
					View on GitHub →
				</a>
			)}
		</div>
	);
}

function TypeContent({
	type,
	payload,
}: { type: WebhookEventType; payload: Record<string, unknown> }) {
	switch (type) {
		case "pull_request": {
			const pr = extractPRDetail(payload);
			if (!pr) return null;
			return <PRContent detail={pr} />;
		}
		case "push": {
			const push = extractPushDetail(payload);
			if (!push) return null;
			return <PushContent detail={push} />;
		}
		case "check_run":
		case "check_suite":
		case "workflow_run": {
			const ci = extractCIDetail(payload);
			if (!ci) return null;
			return <CIContent detail={ci} />;
		}
		case "issues":
		case "issue_comment": {
			const issue = extractIssueDetail(payload);
			if (!issue) return null;
			return <IssueContent detail={issue} />;
		}
		case "discussion":
		case "discussion_comment": {
			const disc = extractDiscussionDetail(payload);
			if (!disc) return null;
			return <DiscussionContent detail={disc} />;
		}
		default:
			return null;
	}
}

function PRContent({ detail }: { detail: PRDetail }) {
	return (
		<>
			{detail.sender && (
				<div className={styles.sender}>{detail.sender}</div>
			)}
			<div className={styles.detailTitle}>{detail.title}</div>
			{detail.body && <div className={styles.body}>{detail.body}</div>}
			<div className={styles.badges}>
				<span className={styles.badge}>+{detail.additions}</span>
				<span className={styles.badge}>-{detail.deletions}</span>
				<span className={styles.badge}>
					{detail.changedFiles} file{detail.changedFiles !== 1 ? "s" : ""}
				</span>
			</div>
		</>
	);
}

function PushContent({ detail }: { detail: PushDetail }) {
	return (
		<>
			<div className={styles.branchName}>Branch: {detail.branch}</div>
			<div className={styles.commitList}>
				{detail.commits.map((c) => (
					<div key={c.sha} className={styles.commit}>
						<span className={styles.commitSha}>{c.sha}</span>
						<span className={styles.commitMsg}>{c.message}</span>
					</div>
				))}
			</div>
		</>
	);
}

function CIContent({ detail }: { detail: CIDetail }) {
	const dotClass =
		detail.conclusion === "success"
			? styles.conclusionSuccess
			: detail.conclusion === "failure"
				? styles.conclusionFailure
				: styles.conclusionNeutral;

	return (
		<>
			<div className={styles.conclusion}>
				<span className={`${styles.conclusionDot} ${dotClass}`} />
				<span className={styles.conclusionText}>
					{detail.name}: {detail.conclusion}
				</span>
			</div>
			{detail.branch && (
				<div className={styles.branchName}>Branch: {detail.branch}</div>
			)}
		</>
	);
}

function IssueContent({ detail }: { detail: IssueDetail }) {
	return (
		<>
			{detail.sender && (
				<div className={styles.sender}>{detail.sender}</div>
			)}
			<div className={styles.detailTitle}>{detail.title}</div>
			{detail.body && <div className={styles.body}>{detail.body}</div>}
			{detail.labels.length > 0 && (
				<div className={styles.badges}>
					{detail.labels.map((l) => (
						<span key={l} className={styles.badge}>
							{l}
						</span>
					))}
				</div>
			)}
		</>
	);
}

function DiscussionContent({ detail }: { detail: DiscussionDetail }) {
	return (
		<>
			{detail.sender && (
				<div className={styles.sender}>{detail.sender}</div>
			)}
			<div className={styles.detailTitle}>{detail.title}</div>
			{detail.body && <div className={styles.body}>{detail.body}</div>}
		</>
	);
}
