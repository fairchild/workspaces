import { authorizeRepoAccess, unauthorizedResponse } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";
import { getEvents, getEventsForRepos } from "@/lib/events";
import { getUserRepos } from "@/lib/repos";

export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session?.user) return unauthorizedResponse();

	const { searchParams } = new URL(request.url);
	const repo = searchParams.get("repo");

	if (repo) {
		const unauthorized = await authorizeRepoAccess(session.user.id, repo);
		if (unauthorized) return unauthorized;
		return Response.json(await getEvents(50, repo));
	}

	const userRepos = await getUserRepos(session.user.id);
	const repoNames = userRepos.map((r) => `${r.owner}/${r.repo}`);
	return Response.json(await getEventsForRepos(repoNames, 50));
}
