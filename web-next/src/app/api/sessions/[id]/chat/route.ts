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
import {
	ApprovalPolicyUnsupportedError,
	runSessionTurn,
	TurnConflictError,
} from "@/lib/agent-runtime/run-turn";
import { sessionOwnerScopeResponse } from "@/lib/auth/session-owner";
import { getDatabase } from "@/lib/db/client";
import { getSession } from "@/lib/db/sessions";

// The real (vercel) provider boots a sandbox and runs a full agent turn; give
// the invocation room to settle via after(). The mock turn finishes in seconds.
export const runtime = "nodejs";
export const maxDuration = 300;

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
	const ownerScope = sessionOwnerScopeResponse(session, auth.user.login);
	if (ownerScope) return ownerScope;

	const body: unknown = await request.json().catch(() => undefined);
	const text =
		typeof body === "object" && body !== null && "text" in body
			? String((body as { text: unknown }).text).trim()
			: "";
	if (text.length === 0) {
		return Response.json({ error: "text is required" }, { status: 400 });
	}

	let turn;
	try {
		turn = await runSessionTurn(handle, session, text);
	} catch (error) {
		// Structured errors, not unhandled 500s: a concurrent send is a 409 the
		// client can retry after the turn; a session naming an unregistered
		// provider is a 500 with the reason.
		if (error instanceof TurnConflictError) {
			return Response.json({ error: error.message }, { status: 409 });
		}
		if (error instanceof ApprovalPolicyUnsupportedError) {
			return Response.json({ error: error.message }, { status: 409 });
		}
		const message = error instanceof Error ? error.message : "failed to start the turn";
		return Response.json({ error: message }, { status: 500 });
	}
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
