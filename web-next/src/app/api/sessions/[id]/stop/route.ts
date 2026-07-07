/*
 * POST /api/sessions/[id]/stop — stop the session's in-flight turn (#753).
 * Auth-gated same as the chat route. Aborts the ingest loop when it runs in
 * this process (the loop closes the turn durably with `error` + aborted
 * `done`, so live tails and reloads agree it was stopped); a turn whose
 * runner already died (stale) is closed the same way. A turn running on
 * another server instance is reported honestly as unreachable rather than
 * having its log closed under a still-appending writer — process-local
 * abort is the only stop the runtime actually supports (see turn-ingest.ts).
 */
import { stopActiveTurn, TURN_STOPPED_MESSAGE } from "@/lib/agent-runtime/turn-ingest";
import { closeAbandonedTurn, resolveTurn } from "@/lib/agent-runtime/turn-tail";
import { getAuthState } from "@/lib/auth/auth-state";
import { getDatabase } from "@/lib/db/client";
import { getSession } from "@/lib/db/sessions";

export const runtime = "nodejs";

export async function POST(
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

	if (stopActiveTurn(id)) {
		return Response.json({ stopped: true, message: TURN_STOPPED_MESSAGE });
	}

	const turn = await resolveTurn(handle, id);
	if (turn.status === "stale" && turn.fromSeq !== null) {
		// The runner died without closing its turn — stopping it means closing
		// the log durably, which is safe precisely because nothing is appending.
		await closeAbandonedTurn(handle, id, turn.fromSeq);
		return Response.json({ stopped: true, message: TURN_STOPPED_MESSAGE });
	}
	if (turn.status === "running") {
		return Response.json(
			{
				error:
					"the turn is running on another server instance and can't be stopped from here",
			},
			{ status: 409 },
		);
	}
	return Response.json({ error: "no turn is running" }, { status: 409 });
}
