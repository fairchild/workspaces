import { getEvents } from "@/lib/events";

export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
	const events = await getEvents();
	return Response.json(events);
}
