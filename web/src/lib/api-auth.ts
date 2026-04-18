import { getUserRepos } from "./repos";

export function unauthorizedResponse(): Response {
	return Response.json({ error: "unauthorized" }, { status: 401 });
}

export async function authorizeRepoAccess(
	userId: string,
	repo: string,
): Promise<Response | null> {
	const userRepos = await getUserRepos(userId);
	if (!userRepos.some((r) => `${r.owner}/${r.repo}` === repo)) {
		return Response.json(
			{ error: "repo not in your workspace" },
			{ status: 403 },
		);
	}
	return null;
}
