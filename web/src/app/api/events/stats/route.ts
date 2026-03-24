import { getEventStats } from "@/lib/events";

export const dynamic = "force-dynamic";

export async function GET(): Promise<Response> {
	const stats = await getEventStats();
	return Response.json(stats);
}
