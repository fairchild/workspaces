/*
 * GET /api/repos?q=<query> — auth-gated feed for the new-session picker's
 * searchable repo list. Backed by the GitHub App installation in real/bypass
 * mode (see `@/lib/github/repo-directory`); returns an empty list with
 * `degraded: true` when the App has no credentials configured, so the client
 * can fall back to an unverified-freetext note instead of an empty-looking
 * error.
 */
import { getAuthState } from "@/lib/auth/auth-state";
import {
	isDirectoryDegraded,
	listDirectoryRepos,
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

	const q = new URL(request.url).searchParams.get("q")?.trim().toLowerCase() ?? "";
	const repos = await listDirectoryRepos();
	const filtered = q
		? repos.filter((repo) => repo.fullName.toLowerCase().includes(q))
		: repos;

	return Response.json({ repos: filtered, degraded: isDirectoryDegraded() });
}
