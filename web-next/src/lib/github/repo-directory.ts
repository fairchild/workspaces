/*
 * GitHub-backed repo directory for the new-session picker: lists the App
 * installation's repositories and validates a freetext `owner/name`, sitting
 * in front of the raw App-auth mechanics in `../diag/github-app`. Three modes,
 * resolved once per call so callers never branch on environment themselves:
 *
 *  - bypass (`AUTH_BYPASS=1`, no real OAuth configured — see `../auth/config`):
 *    a small deterministic fixture set, so e2e/evidence/perf runs never touch
 *    the real GitHub API.
 *  - configured (App creds present): the real installation-repos + repo-read
 *    endpoints.
 *  - degraded (App creds absent, e.g. local dev without `.env.local`): listing
 *    comes back empty and validation always resolves "unverified" rather than
 *    blocking — freetext still works, just unproven.
 */
import { authBypassEnabled } from "../auth/config";
import {
	type DirectoryRepo,
	listInstallationRepositories,
	mintDirectoryToken,
	mintInstallationToken,
	verifyRepoAccess,
} from "../diag/github-app";

export type { DirectoryRepo };

/** Thrown by `resolveRepo` when GitHub says a repo doesn't exist or isn't accessible to the App. */
export class RepoUnavailableError extends Error {
	constructor(public readonly fullName: string) {
		super(`${fullName} doesn't exist or isn't accessible to the GitHub App`);
		this.name = "RepoUnavailableError";
	}
}

export type RepoValidation =
	| ({ kind: "ok" } & DirectoryRepo)
	| { kind: "not-found"; fullName: string }
	/** Degraded mode: no App creds to check against, so we don't block. */
	| { kind: "unverified"; fullName: string };

const FIXTURE_REPOS: DirectoryRepo[] = [
	{ fullName: "fairchild/workspaces", defaultBranch: "main", private: false },
	{ fullName: "fairchild/dotfiles", defaultBranch: "main", private: false },
	{
		fullName: "fairchild/web-next-fixtures",
		defaultBranch: "trunk",
		private: true,
	},
];

function hasAppCredentials(): boolean {
	return Boolean(
		process.env.GITHUB_WEB_WORKSPACES_APP_ID && process.env.GITHUB_APP_PRIVATE_KEY,
	);
}

/** True when the picker has nothing but the freetext escape hatch to offer. */
export function isDirectoryDegraded(): boolean {
	return !authBypassEnabled() && !hasAppCredentials();
}

/** The installation's repos, alphabetical — empty (not thrown) when degraded. */
export async function listDirectoryRepos(): Promise<DirectoryRepo[]> {
	if (authBypassEnabled()) {
		return [...FIXTURE_REPOS].sort((a, b) => a.fullName.localeCompare(b.fullName));
	}
	if (!hasAppCredentials()) return [];
	const { token } = await mintDirectoryToken();
	const repos = await listInstallationRepositories(token);
	return repos.sort((a, b) => a.fullName.localeCompare(b.fullName));
}

/** Validates `fullName` against GitHub (or the fixture/degraded stand-ins). */
export async function validateDirectoryRepo(
	fullName: string,
): Promise<RepoValidation> {
	if (authBypassEnabled()) {
		const fixture = FIXTURE_REPOS.find(
			(repo) => repo.fullName.toLowerCase() === fullName.toLowerCase(),
		);
		return fixture ? { kind: "ok", ...fixture } : { kind: "not-found", fullName };
	}
	if (!hasAppCredentials()) return { kind: "unverified", fullName };
	try {
		const { token } = await mintInstallationToken(fullName);
		const repo = await verifyRepoAccess(token, fullName);
		return { kind: "ok", ...repo };
	} catch {
		// GitHub 404s a repo the App has no access to the same way it 404s one
		// that doesn't exist at all (deliberate, to avoid leaking private-repo
		// existence) — this directory can't distinguish the two either.
		return { kind: "not-found", fullName };
	}
}

/**
 * The write path's entry point: validate `fullName` and return the
 * `default_branch` to record, or throw `RepoUnavailableError` for the caller
 * to turn into a calm inline message. Degraded mode never throws.
 */
export async function resolveRepo(
	fullName: string,
): Promise<{ defaultBranch: string | null }> {
	const result = await validateDirectoryRepo(fullName);
	if (result.kind === "not-found") throw new RepoUnavailableError(fullName);
	if (result.kind === "unverified") return { defaultBranch: null };
	return { defaultBranch: result.defaultBranch };
}
