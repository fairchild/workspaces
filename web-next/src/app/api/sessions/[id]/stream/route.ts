/*
 * GET /api/sessions/[id]/stream — the AI SDK reconnect target. useChat's
 * `resume` / `resumeStream()` issues a GET here to catch up to an in-flight
 * turn. Same auth gate as the send route (a data-reading route the middleware's
 * freshness check does not fully cover). Returns 204 when there is nothing to
 * resume (no turn, or the turn already finished — the client already has it via
 * SSR); otherwise streams the turn tailed from the durable log to completion.
 * A stale (runner-died) turn is first closed durably, then streamed so the
 * client sees it end rather than hang.
 */
import { createUIMessageStreamResponse } from "ai";
import { getAuthState } from "@/lib/auth/auth-state";
import { closeAbandonedTurn, resolveTurn, tailStream } from "@/lib/agent-runtime/turn-tail";
import { getDatabase } from "@/lib/db/client";
import { getSession } from "@/lib/db/sessions";

export async function GET(
	_request: Request,
	{ params }: { params: Promise<{ id: string }> },
) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const { id } = await params;
	const handle = getDatabase();
	const session = await getSession(handle, id);
	if (!session) {
		return Response.json({ error: "unknown session" }, { status: 404 });
	}

	const turn = await resolveTurn(handle, id);
	if (turn.status === "none" || turn.status === "done" || turn.fromSeq === null) {
		// No active stream to resume — the AI SDK client treats 204 as "done".
		return new Response(null, { status: 204 });
	}
	if (turn.status === "stale") {
		await closeAbandonedTurn(handle, id, turn.fromSeq);
	}
	return createUIMessageStreamResponse({
		stream: tailStream(handle, id, turn.fromSeq),
	});
}
