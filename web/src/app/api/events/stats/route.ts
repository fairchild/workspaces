import { getEventStats } from "@/lib/events";

export async function GET(): Promise<Response> {
	const stats = await getEventStats();
	return Response.json(stats);
}
