/*
 * POST /api/sessions/[id]/chat — send a message to a session. Auth-gated
 * (same allowlist verdict as the pages; middleware freshness is not enough
 * for a data-writing route), then delegates to runSessionTurn: the user event
 * and the provider's chunks land in session_events while the adapted
 * UIMessage stream flows back to useChat.
 */
import { createUIMessageStreamResponse } from "ai";
import { after } from "next/server";
import { getAuthState } from "@/lib/auth/auth-state";
import { runSessionTurn } from "@/lib/agent-runtime/run-turn";
import { getDatabase } from "@/lib/db/client";
import { getSession } from "@/lib/db/sessions";

export async function POST(
	request: Request,
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

	const body: unknown = await request.json().catch(() => undefined);
	const text =
		typeof body === "object" && body !== null && "text" in body
			? String((body as { text: unknown }).text).trim()
			: "";
	if (text.length === 0) {
		return Response.json({ error: "text is required" }, { status: 400 });
	}

	const turn = await runSessionTurn(handle, session, text);
	// The ingest loop already runs eagerly (the stream below tails it live).
	// after() keeps a serverless invocation alive until the turn settles — the
	// waitUntil seam; a no-op on a long-running node server. after() is only
	// valid in a request scope, so guard it (unit tests call runSessionTurn
	// directly, outside one).
	try {
		after(() => turn.ingest);
	} catch {
		// Not in a request scope (e.g. a test harness) — ingest still runs.
	}
	return createUIMessageStreamResponse({ stream: turn.stream });
}
