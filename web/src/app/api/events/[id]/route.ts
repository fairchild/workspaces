import { getEvent } from "@/lib/events";

export const dynamic = "force-dynamic";

export async function GET(
	_request: Request,
	{ params }: { params: Promise<{ id: string }> },
): Promise<Response> {
	const { id } = await params;
	const event = await getEvent(id);
	if (!event) return new Response(null, { status: 404 });
	return Response.json(event);
}
