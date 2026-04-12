import { unauthorizedResponse } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";
import { getUserRepos, setUserRepos } from "@/lib/repos";

export async function GET(): Promise<Response> {
	const session = await getSession();
	if (!session) return unauthorizedResponse();

	const repos = await getUserRepos(session.user.id);
	return Response.json(repos);
}

export async function POST(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session) return unauthorizedResponse();

	const body = (await request.json()) as {
		repos: Array<{ owner: string; repo: string }>;
	};

	if (!Array.isArray(body.repos)) {
		return Response.json({ error: "repos must be an array" }, { status: 400 });
	}

	await setUserRepos(session.user.id, body.repos);
	return Response.json({ ok: true });
}
