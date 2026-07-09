/*
 * PR-from-session orchestration (#820): compose the draft PR body and bridge
 * the app route to the Vercel sandbox command. The route owns auth/session
 * scoping; this module owns provider guardrails and row updates.
 */
import type { Repo } from "../db/repos";
import type { Session, SessionPullRequest } from "../db/sessions";
import { readEvents, updateSession } from "../db/sessions";
import type { DatabaseHandle } from "../db/client";
import { projectSessionEvents } from "../transcript/project-events";
import type { FolioMessage } from "@/components/folio/types";
import {
	openPullRequestFromVercelSession,
	PullRequestCommandFailed,
	sessionBranch,
} from "./vercel-provider";
import type { SessionResumeHandle } from "./provider";

export interface SessionPrResponse {
	pullRequest: SessionPullRequest;
	hasUnpushedWork: boolean;
}

export class SessionPrError extends Error {
	constructor(
		readonly code: string,
		message: string,
		readonly status: number,
	) {
		super(message);
		this.name = "SessionPrError";
	}
}

function titleFor(session: Session): string {
	const title = session.title.trim();
	return title || `Session ${session.id.slice(0, 8)}`;
}

function userText(message: FolioMessage): string {
	return message.parts
		.filter((part) => part.type === "text")
		.map((part) => part.text)
		.join("")
		.trim();
}

function assistantReceipt(message: FolioMessage): string {
	const stats = message.metadata?.turnStats;
	if (message.metadata?.error) return `failed: ${message.metadata.error}`;
	if (!stats) return "completed";
	const pieces = [`${stats.toolCount} tools`, `${(stats.durationMs / 1000).toFixed(1)}s`];
	if (stats.tokenCount !== undefined) pieces.push(`${stats.tokenCount} tokens`);
	return pieces.join(", ");
}

export async function composeSessionPullRequestBody({
	handle,
	session,
	repo,
	sessionUrl,
}: {
	handle: DatabaseHandle;
	session: Session;
	repo: Repo;
	sessionUrl: string;
}): Promise<string> {
	const transcript = (await projectSessionEvents(
		session.id,
		await readEvents(handle, session.id),
	)) as FolioMessage[];
	const lines = [
		`Draft PR opened from Spaces session ${session.id}.`,
		"",
		`Session: ${sessionUrl}`,
		`Repository: ${repo.fullName}`,
		`Branch: ${sessionBranch(session.id)}`,
		`Base: ${repo.defaultBranch ?? "default branch"}`,
		"",
		"## Turn Receipts",
	];
	let turn = 0;
	for (const message of transcript) {
		if (message.role === "user") {
			turn += 1;
			const text = userText(message);
			lines.push(
				`${turn}. ${text ? text.replace(/\s+/g, " ").slice(0, 120) : "User turn"}`,
			);
		} else if (turn > 0) {
			lines.push(`   - Claude ${assistantReceipt(message)}`);
		}
	}
	if (turn === 0) lines.push("- No completed turns were recorded.");
	lines.push("", "_Created by the GitHub App installation token for this session._");
	return lines.join("\n");
}

function resumeHandle(session: Session): SessionResumeHandle | null {
	if (!session.claudeSessionId || !session.resumeState) return null;
	return {
		harnessSessionId: session.claudeSessionId,
		resumeState: session.resumeState,
	};
}

async function persistResume(
	handle: DatabaseHandle,
	sessionId: string,
	resume: SessionResumeHandle | null | undefined,
): Promise<void> {
	if (resume === undefined) return;
	if (resume === null) {
		await updateSession(handle, sessionId, {
			claudeSessionId: null,
			resumeState: null,
		});
		return;
	}
	await updateSession(handle, sessionId, {
		claudeSessionId: resume.harnessSessionId,
		resumeState: resume.resumeState,
	});
}

export async function openSessionPullRequest({
	handle,
	session,
	repo,
	sessionUrl,
}: {
	handle: DatabaseHandle;
	session: Session;
	repo: Repo | undefined;
	sessionUrl: string;
}): Promise<SessionPrResponse> {
	if (session.pullRequest && !session.hasUnpushedWork) {
		return { pullRequest: session.pullRequest, hasUnpushedWork: false };
	}
	if (session.provider !== "vercel") {
		throw new SessionPrError(
			"unsupported_provider",
			session.provider === "host"
				? "PRs from host-provider sessions need a separate credential story."
				: "This session provider has no sandbox-backed PR action.",
			409,
		);
	}
	if (!repo) {
		throw new SessionPrError(
			"missing_repo",
			"PRs can only be opened for a connected repository.",
			409,
		);
	}
	const resume = resumeHandle(session);
	if (!resume) {
		throw new SessionPrError(
			"sandbox_unavailable",
			"The session sandbox is not parked; run another turn before opening a PR.",
			409,
		);
	}
	if (!session.hasUnpushedWork && !session.pullRequest) {
		throw new SessionPrError(
			"no_unpushed_work",
			"This session has no checkpoint commits ready for a PR.",
			409,
		);
	}

	const body = await composeSessionPullRequestBody({
		handle,
		session,
		repo,
		sessionUrl,
	});
	try {
		const pr = await openPullRequestFromVercelSession({
			sessionId: session.id,
			repo: { fullName: repo.fullName, defaultBranch: repo.defaultBranch },
			resume,
			title: titleFor(session),
			body,
		});
		const pullRequest = {
			number: pr.number,
			url: pr.url,
			state: pr.state,
		};
		await updateSession(handle, session.id, {
			hasUnpushedWork: false,
			pullRequest,
			claudeSessionId: pr.resume?.harnessSessionId ?? null,
			resumeState: pr.resume?.resumeState ?? null,
		});
		return { pullRequest, hasUnpushedWork: false };
	} catch (error) {
		if (error instanceof PullRequestCommandFailed) {
			await persistResume(handle, session.id, error.resume);
			throw new SessionPrError("pr_command_failed", error.message, 502);
		}
		throw error;
	}
}
