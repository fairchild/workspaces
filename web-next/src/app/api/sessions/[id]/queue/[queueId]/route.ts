/*
 * DELETE /api/sessions/[id]/queue/[queueId] — cancel a durable mid-turn
 * steering message before it dispatches. Dispatched rows are immutable because
 * their text has already entered session_events as a normal user turn.
 */
import { getAuthState } from "@/lib/auth/auth-state";
import { sessionOwnerScopeResponse } from "@/lib/auth/session-owner";
import { getDatabase } from "@/lib/db/client";
import { cancelQueuedMessage } from "@/lib/db/queued-messages";
import { getSession } from "@/lib/db/sessions";

export const runtime = "nodejs";

export async function DELETE(
	_request: Request,
	{ params }: { params: Promise<{ id: string; queueId: string }> },
) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const { id, queueId } = await params;
	const handle = getDatabase();
	const session = await getSession(handle, id);
	if (!session) {
		return Response.json({ error: "unknown session" }, { status: 404 });
	}
	const ownerScope = sessionOwnerScopeResponse(session, auth.user.login);
	if (ownerScope) return ownerScope;

	const result = await cancelQueuedMessage(handle, id, queueId);
	if (result === "canceled") {
		return Response.json({ canceled: true, queueId });
	}
	if (result === "dispatched") {
		return Response.json(
			{ error: "queued message has already dispatched" },
			{ status: 409 },
		);
	}
	return Response.json({ error: "queued message not found" }, { status: 404 });
}
