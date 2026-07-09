/*
 * POST /api/sessions/[id]/pr — user-triggered PR-from-session action (#820).
 * Auth and owner scoped like sibling session mutations, then delegates to the
 * Vercel sandbox command that pushes the session branch and opens a draft PR.
 */
import { resolveTurn } from "@/lib/agent-runtime/turn-tail";
import {
	openSessionPullRequest,
	SessionPrError,
} from "@/lib/agent-runtime/session-pr";
import { getAuthState } from "@/lib/auth/auth-state";
import { sessionOwnerScopeResponse } from "@/lib/auth/session-owner";
import { getDatabase } from "@/lib/db/client";
import { getRepo } from "@/lib/db/repos";
import { getSession } from "@/lib/db/sessions";

export const runtime = "nodejs";
export const maxDuration = 300;

export async function POST(
	request: Request,
	{ params }: { params: Promise<{ id: string }> },
) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user", code: "unauthorized" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const { id } = await params;
	const handle = getDatabase();
	const session = await getSession(handle, id);
	if (!session) {
		return Response.json({ error: "unknown session", code: "not_found" }, { status: 404 });
	}
	const ownerScope = sessionOwnerScopeResponse(session, auth.user.login);
	if (ownerScope) return ownerScope;

	const turn = await resolveTurn(handle, id);
	if (turn.status === "running" || turn.status === "stale") {
		return Response.json(
			{
				error: "wait for the current turn to finish before opening a PR",
				code: "turn_running",
			},
			{ status: 409 },
		);
	}

	const repo = session.repoId ? await getRepo(handle, session.repoId) : undefined;
	const sessionUrl = new URL(`/sessions/${id}`, request.url).toString();
	try {
		const result = await openSessionPullRequest({
			handle,
			session,
			repo,
			sessionUrl,
		});
		return Response.json(result);
	} catch (error) {
		if (error instanceof SessionPrError) {
			return Response.json(
				{ error: error.message, code: error.code },
				{ status: error.status },
			);
		}
		const message =
			error instanceof Error ? error.message : "failed to open the pull request";
		return Response.json(
			{ error: message, code: "internal_error" },
			{ status: 500 },
		);
	}
}
