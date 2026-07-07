/*
 * GET /api/repos?q=<query> — auth-gated feed for the new-session picker's
 * searchable repo list: the GitHub App installation's repos merged with the
 * already-connected ones (see mergeRepoLists), so one-click rows survive
 * even when the directory is empty. `degraded: true` when the App has no
 * credentials configured, so the client can show the quiet unverified note
 * instead of an empty-looking error.
 */
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { listRepos } from "@/lib/db/repos";
import {
	isDirectoryDegraded,
	listDirectoryRepos,
	mergeRepoLists,
} from "@/lib/github/repo-directory";

export const runtime = "nodejs";

export async function GET(request: Request) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const [directory, connected] = await Promise.all([
		listDirectoryRepos(),
		listRepos(getDatabase()),
	]);
	const repos = mergeRepoLists(directory, connected);

	const q = new URL(request.url).searchParams.get("q")?.trim().toLowerCase() ?? "";
	const filtered = q
		? repos.filter((repo) => repo.fullName.toLowerCase().includes(q))
		: repos;

	return Response.json({ repos: filtered, degraded: isDirectoryDegraded() });
}
