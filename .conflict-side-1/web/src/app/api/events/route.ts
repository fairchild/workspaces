import { getEvents } from "@/lib/events";

export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
	const { searchParams } = new URL(request.url);
	const repo = searchParams.get("repo");
	const events = await getEvents(50, repo);
	return Response.json(events);
}
