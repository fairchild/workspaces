import { getEvents } from "@/lib/events";

export async function GET(): Promise<Response> {
	return Response.json(getEvents());
}
