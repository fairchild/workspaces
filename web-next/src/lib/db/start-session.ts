/*
 * The new-session flow's write path: validate an `owner/name`, connect the
 * repo on first use, and create the session row the user is routed to.
 * Pure orchestration over repos.ts + sessions.ts so its callers — the UI
 * server action, GET /new, and POST /api/sessions — stay thin auth-gated
 * shells around one shared resolution path.
 */
import type { DatabaseHandle } from "./client";
import { RepoUnavailableError, resolveRepo } from "../github/repo-directory";
import { ensureRepo } from "./repos";
import { createSession, type Session } from "./sessions";

export { RepoUnavailableError };

// GitHub's rules, loosely: owner and name from [A-Za-z0-9_.-], no slashes
// beyond the separator. This is the shape check only; existence + access are
// confirmed against GitHub by resolveRepo() below.
const REPO_FULL_NAME = /^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9_.-]+$/;

export function isValidRepoFullName(value: string): boolean {
	return REPO_FULL_NAME.test(value);
}

/**
 * Which compute provider new sessions run on. Defaults to the mock; set
 * `WEB_NEXT_COMPUTE_PROVIDER=vercel` or `WEB_NEXT_COMPUTE_PROVIDER=host` to
 * route new sessions to a real runtime.
 */
export function defaultComputeProvider(): string {
	return process.env.WEB_NEXT_COMPUTE_PROVIDER ?? "mock";
}

/**
 * The embedded-native contract reserves `path=` for Milestone 2 (workspace
 * path binding); until then every session-create surface refuses it loudly
 * rather than silently ignoring it.
 */
export const PATH_PARAM_UNSUPPORTED =
	"path binding is not yet supported (see embedded-native-contract.md, Milestone 2)";

export interface StartSessionOptions {
	ownerLogin?: string | null;
	/** Pre-cleaned title (see `lib/session-title`); empty until a turn names it. */
	title?: string;
	/** Compute provider; `defaultComputeProvider()` when omitted. */
	provider?: string;
}

/**
 * Creates (or reuses) the repo and starts an empty session on it. Validates
 * `repoFullName` against GitHub first (see `../github/repo-directory`) —
 * throws `RepoUnavailableError` if it doesn't exist or isn't accessible to
 * the App — and records the real default branch on connect.
 */
export async function startSession(
	handle: DatabaseHandle,
	repoFullName: string,
	options: StartSessionOptions = {},
): Promise<Session> {
	const trimmed = repoFullName.trim();
	if (!isValidRepoFullName(trimmed)) {
		throw new Error(`not an owner/name repository: ${JSON.stringify(trimmed)}`);
	}
	const { defaultBranch } = await resolveRepo(trimmed);
	const repo = await ensureRepo(handle, trimmed, defaultBranch);
	return createSession(handle, {
		id: crypto.randomUUID(),
		repoId: repo.id,
		ownerLogin: options.ownerLogin,
		title: options.title,
		provider: options.provider ?? defaultComputeProvider(),
	});
}
