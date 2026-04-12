import { unauthorizedResponse } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";
import { getEventStatsForRepos } from "@/lib/events";
import { getUserRepos } from "@/lib/repos";

export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
	const session = await getSession();
	if (!session?.user) return unauthorizedResponse();

	const userRepos = await getUserRepos(session.user.id);
	const repoNames = userRepos.map((r) => `${r.owner}/${r.repo}`);
	return Response.json(await getEventStatsForRepos(repoNames));
}
