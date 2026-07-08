/*
 * POST /api/sessions/[id]/approvals/[requestId] — answer a pending provider
 * permission request. This route updates turn_approvals and wakes the broker;
 * it deliberately does not append session_events, preserving the ingest loop
 * as the transcript log's only writer.
 */
import { answerApproval } from "@/lib/agent-runtime/approval-broker";
import type { ApprovalDecision } from "@/lib/agent-runtime/stream-chunk";
import { getAuthState } from "@/lib/auth/auth-state";
import { sessionOwnerScopeResponse } from "@/lib/auth/session-owner";
import { getDatabase } from "@/lib/db/client";
import { getSession } from "@/lib/db/sessions";

export const runtime = "nodejs";

function parseDecision(body: unknown): ApprovalDecision | undefined {
	if (typeof body !== "object" || body === null) return undefined;
	const decision = (body as { decision?: unknown }).decision;
	return decision === "allow" || decision === "deny" ? decision : undefined;
}

export async function POST(
	request: Request,
	{ params }: { params: Promise<{ id: string; requestId: string }> },
) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const { id, requestId } = await params;
	const handle = getDatabase();
	const session = await getSession(handle, id);
	if (!session) {
		return Response.json({ error: "unknown session" }, { status: 404 });
	}
	const ownerScope = sessionOwnerScopeResponse(session, auth.user.login);
	if (ownerScope) return ownerScope;

	const body: unknown = await request.json().catch(() => undefined);
	const decision = parseDecision(body);
	if (!decision) {
		return Response.json(
			{ error: 'decision must be "allow" or "deny"' },
			{ status: 400 },
		);
	}

	const result = await answerApproval(handle, {
		sessionId: id,
		requestId,
		decision,
	});
	if (result.status === "unknown") {
		return Response.json({ error: "unknown approval request" }, { status: 404 });
	}
	if (result.status === "already-decided") {
		return Response.json(
			{ error: "approval request already decided" },
			{ status: 409 },
		);
	}
	if (result.status === "expired") {
		return Response.json({ error: "approval request expired" }, { status: 409 });
	}

	return Response.json({
		requestId,
		decision: result.resolution.decision,
		resolvedBy: result.resolution.resolvedBy,
	});
}
