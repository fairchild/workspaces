/*
 * The session's sandbox lifecycle surface (#753). GET reports the sandbox's
 * real state (live / parked / none — checked against the platform, never
 * inferred) and sweeps parked live VMs after the adaptive idle window; DELETE
 * stops a live VM and reports the state that's actually left. Auth-gated same
 * as the chat route; both verbs are safe to repeat — a re-GET re-checks, a
 * re-DELETE of an already-parked sandbox is a no-op that returns the honest
 * current state.
 */
import {
	resolveSandboxState,
	stopSessionSandbox,
} from "@/lib/agent-runtime/sandbox-state";
import { getAuthState } from "@/lib/auth/auth-state";
import { sessionOwnerScopeResponse } from "@/lib/auth/session-owner";
import { getDatabase } from "@/lib/db/client";
import { getSession } from "@/lib/db/sessions";

export const runtime = "nodejs";

async function gate(id: string, options: { ownerScoped?: boolean } = {}) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return {
			response: Response.json(
				{ error: "not signed in as the allowed user" },
				{ status: auth.kind === "unauthenticated" ? 401 : 403 },
			),
		};
	}
	const session = await getSession(getDatabase(), id);
	if (!session) {
		return {
			response: Response.json({ error: "unknown session" }, { status: 404 }),
		};
	}
	if (options.ownerScoped) {
		const ownerScope = sessionOwnerScopeResponse(session, auth.user.login);
		if (ownerScope) return { response: ownerScope };
	}
	return { session };
}

export async function GET(
	_request: Request,
	{ params }: { params: Promise<{ id: string }> },
) {
	const { id } = await params;
	const gated = await gate(id);
	if (gated.response) return gated.response;
	return Response.json(await resolveSandboxState(gated.session));
}

export async function DELETE(
	_request: Request,
	{ params }: { params: Promise<{ id: string }> },
) {
	const { id } = await params;
	const gated = await gate(id, { ownerScoped: true });
	if (gated.response) return gated.response;
	try {
		return Response.json(await stopSessionSandbox(gated.session));
	} catch (error) {
		const message =
			error instanceof Error ? error.message : "failed to stop the sandbox";
		return Response.json({ error: message }, { status: 502 });
	}
}
