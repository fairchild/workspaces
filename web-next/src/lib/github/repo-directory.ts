/*
 * GitHub-backed repo directory for the new-session picker: lists the App
 * installation's repositories and validates a freetext `owner/name`, sitting
 * in front of the raw App-auth mechanics in `../diag/github-app`. Directory
 * mode is credential-driven, not auth-driven:
 *
 *  - configured (App creds present): the real installation-repos + repo-read
 *    endpoints.
 *  - fixtures (App creds absent): a small deterministic fixture set, so
 *    e2e/evidence/perf runs stay hermetic and local mode has a visible picker.
 */
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
	| { kind: "not-found"; fullName: string };

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

/** No degraded mode now: no App creds means deterministic fixtures, not empty. */
export function isDirectoryDegraded(): boolean {
	return false;
}

/** The installation's repos, or deterministic fixtures when App creds are absent. */
export async function listDirectoryRepos(): Promise<DirectoryRepo[]> {
	if (!hasAppCredentials()) {
		return [...FIXTURE_REPOS].sort((a, b) => a.fullName.localeCompare(b.fullName));
	}
	const { token } = await mintDirectoryToken();
	const repos = await listInstallationRepositories(token);
	return repos.sort((a, b) => a.fullName.localeCompare(b.fullName));
}

/** Validates `fullName` against GitHub (or the fixture/degraded stand-ins). */
export async function validateDirectoryRepo(
	fullName: string,
): Promise<RepoValidation> {
	if (!hasAppCredentials()) {
		const fixture = FIXTURE_REPOS.find(
			(repo) => repo.fullName.toLowerCase() === fullName.toLowerCase(),
		);
		return fixture ? { kind: "ok", ...fixture } : { kind: "not-found", fullName };
	}
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
	return { defaultBranch: result.defaultBranch };
}

/** What the picker renders: already-connected repos may lack a known branch. */
export interface PickerRepo {
	fullName: string;
	defaultBranch: string | null;
}

/**
 * The picker's full list: the GitHub directory plus the repos already
 * connected in the database (which may include entries the directory can't
 * see — unverified degraded-mode connects, or repos whose App grant was
 * since revoked). Deduped by full name — the directory entry wins, its
 * branch is fresher — and sorted. Keeps one-click rows available even when
 * the directory is empty (degraded mode).
 */
export function mergeRepoLists(
	directory: DirectoryRepo[],
	connected: PickerRepo[],
): PickerRepo[] {
	const byName = new Map<string, PickerRepo>();
	for (const repo of connected) {
		byName.set(repo.fullName.toLowerCase(), {
			fullName: repo.fullName,
			defaultBranch: repo.defaultBranch,
		});
	}
	for (const repo of directory) {
		byName.set(repo.fullName.toLowerCase(), {
			fullName: repo.fullName,
			defaultBranch: repo.defaultBranch,
		});
	}
	return [...byName.values()].sort((a, b) => a.fullName.localeCompare(b.fullName));
}
