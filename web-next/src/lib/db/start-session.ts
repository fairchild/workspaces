/*
 * The new-session flow's write path: validate an `owner/name`, connect the
 * repo on first use, and create the session row the user is routed to.
 * Pure orchestration over repos.ts + sessions.ts so the server action
 * stays a thin auth-gated shell.
 */
import type { DatabaseHandle } from "./client";
import { ensureRepo } from "./repos";
import { createSession, type Session } from "./sessions";

// GitHub's rules, loosely: owner and name from [A-Za-z0-9_.-], no slashes
// beyond the separator. No API validation yet (single-user; typos are the
// user's own repos to correct).
const REPO_FULL_NAME = /^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9_.-]+$/;

export function isValidRepoFullName(value: string): boolean {
	return REPO_FULL_NAME.test(value);
}

/**
 * Creates (or reuses) the repo and starts an empty session on it.
 * Title stays empty until a first turn names it; provider is the mock
 * until #748 wires real compute.
 */
export async function startSession(
	handle: DatabaseHandle,
	repoFullName: string,
): Promise<Session> {
	const trimmed = repoFullName.trim();
	if (!isValidRepoFullName(trimmed)) {
		throw new Error(`not an owner/name repository: ${JSON.stringify(trimmed)}`);
	}
	const repo = await ensureRepo(handle, trimmed);
	return createSession(handle, {
		id: crypto.randomUUID(),
		repoId: repo.id,
		provider: "mock",
	});
}
