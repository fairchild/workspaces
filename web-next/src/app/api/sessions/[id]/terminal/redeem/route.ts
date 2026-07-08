/*
 * POST /api/sessions/[id]/terminal/redeem — exchange a single-use ticket for
 * the terminal transport (#752). Auth-gated again (a ticket alone is never
 * enough), ticket in the POST body (never a URL), bound to this session and
 * the login it was minted for. "ttyd" tickets re-resolve the live sandbox and
 * verify it is still the one the ticket was pinned to before revealing the
 * WebSocket URL; "mock" tickets (AUTH_BYPASS) just confirm the mode.
 */
import { getAuthState } from "@/lib/auth/auth-state";
import { sessionOwnerScopeResponse } from "@/lib/auth/session-owner";
import { getDatabase } from "@/lib/db/client";
import { getSession } from "@/lib/db/sessions";
import {
	ensureTerminal,
	resolveLiveSandbox,
	TerminalUnsupportedError,
} from "@/lib/terminal/sandbox-terminal";
import { redeemTerminalTicket } from "@/lib/terminal/tickets";

export const runtime = "nodejs";

function redeemFailure(reason: string): Response {
	const gone = reason === "expired" || reason === "redeemed";
	return Response.json(
		{ error: gone ? `terminal ticket ${reason}` : "terminal ticket denied" },
		{ status: gone ? 410 : 403 },
	);
}

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
	const ticket =
		typeof body === "object" && body !== null && "ticket" in body
			? String((body as { ticket: unknown }).ticket)
			: "";
	if (ticket.length === 0) {
		return Response.json({ error: "ticket is required" }, { status: 400 });
	}

	const redeemed = await redeemTerminalTicket(handle, ticket, {
		login: auth.user.login,
		sessionId: id,
	});
	if (!redeemed.ok) return redeemFailure(redeemed.reason);

	if (redeemed.record.mode === "mock") {
		return Response.json({ mode: "mock" });
	}

	const live = await resolveLiveSandbox(session);
	if (live.state === "none" || live.sandbox.name !== redeemed.record.sandboxName) {
		return Response.json(
			{ error: "the session's sandbox is no longer running" },
			{ status: 409 },
		);
	}
	try {
		const { wsUrl } = await ensureTerminal(live.sandbox);
		return Response.json({ mode: "ttyd", wsUrl });
	} catch (error) {
		const message =
			error instanceof TerminalUnsupportedError
				? error.message
				: error instanceof Error
					? error.message
					: "terminal setup failed";
		return Response.json({ error: message }, { status: 502 });
	}
}
