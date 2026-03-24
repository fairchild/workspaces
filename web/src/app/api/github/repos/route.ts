import { getSession } from "@/lib/auth-server";
import { fetchUserRepos, getGitHubToken } from "@/lib/github";

export async function GET(): Promise<Response> {
	const session = await getSession();
	if (!session)
		return Response.json({ error: "unauthorized" }, { status: 401 });

	const token = await getGitHubToken(session.user.id);
	if (!token)
		return Response.json(
			{ error: "no_github_token", needsReauth: true },
			{ status: 403 },
		);

	const repos = await fetchUserRepos(token);
	return Response.json(repos);
}
