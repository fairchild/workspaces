import { getSession } from "@/lib/auth-server";
import { GitHubApiError, fetchUserRepos, getGitHubToken } from "@/lib/github";

export async function GET(): Promise<Response> {
	const session = await getSession();
	if (!session)
		return Response.json({ error: "unauthorized" }, { status: 401 });

	try {
		const token = await getGitHubToken(session.user.id);
		if (!token)
			return Response.json(
				{ error: "no_github_token", needsReauth: true },
				{ status: 403 },
			);

		const repos = await fetchUserRepos(token);
		return Response.json(repos);
	} catch (err) {
		if (err instanceof GitHubApiError && err.status === 401) {
			return Response.json(
				{ error: "token_expired", needsReauth: true },
				{ status: 401 },
			);
		}
		const message =
			err instanceof GitHubApiError
				? `GitHub API ${err.status}`
				: err instanceof Error
					? err.message
					: "unknown error";
		console.error("[/api/github/repos]", message, err);
		return Response.json({ error: message }, { status: 500 });
	}
}
