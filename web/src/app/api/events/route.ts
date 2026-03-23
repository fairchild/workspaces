import { getEvents } from "@/lib/events";

export async function GET(): Promise<Response> {
	const events = await getEvents();
	return Response.json(events);
}
