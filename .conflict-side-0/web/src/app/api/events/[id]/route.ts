import { authorizeRepoAccess, unauthorizedResponse } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";
import { getEvent } from "@/lib/events";

export const dynamic = "force-dynamic";

export async function GET(
	_request: Request,
	{ params }: { params: Promise<{ id: string }> },
): Promise<Response> {
	const session = await getSession();
	if (!session?.user) return unauthorizedResponse();

	const { id } = await params;
	const event = await getEvent(id);
	if (!event) return new Response(null, { status: 404 });

	const unauthorized = await authorizeRepoAccess(session.user.id, event.repo);
	if (unauthorized) return unauthorized;

	return Response.json(event);
}
