import { authorizeRepoAccess, unauthorizedResponse } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";
import { getLastEventTime } from "@/lib/events";

export async function GET(
	_request: Request,
	{ params }: { params: Promise<{ owner: string; repo: string }> },
): Promise<Response> {
	const session = await getSession();
	if (!session) return unauthorizedResponse();

	const { owner, repo } = await params;
	const fullName = `${owner}/${repo}`;
	const unauthorized = await authorizeRepoAccess(session.user.id, fullName);
	if (unauthorized) return unauthorized;

	const lastEvent = await getLastEventTime(fullName);

	return Response.json({ lastEvent, connected: lastEvent !== null });
}
