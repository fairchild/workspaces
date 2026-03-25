import { getSession } from "@/lib/auth-server";
import { getLastEventTime } from "@/lib/events";

export async function GET(
	_request: Request,
	{ params }: { params: Promise<{ owner: string; repo: string }> },
): Promise<Response> {
	const session = await getSession();
	if (!session)
		return Response.json({ error: "unauthorized" }, { status: 401 });

	const { owner, repo } = await params;
	const fullName = `${owner}/${repo}`;
	const lastEvent = await getLastEventTime(fullName);

	return Response.json({ lastEvent, connected: lastEvent !== null });
}
