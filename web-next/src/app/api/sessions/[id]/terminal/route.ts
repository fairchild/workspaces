/*
 * POST /api/sessions/[id]/terminal — mint a terminal access ticket (#752).
 * Auth-gated like the chat route (same allowlist verdict), then resolves the
 * session's LIVE sandbox: live → ensure ttyd + issue a single-use 30s ticket
 * (redeemed at ./redeem for the WebSocket URL — the ticket travels only in
 * POST bodies, never a URL); no live sandbox → a calm `no-sandbox` state the
 * drawer renders honestly (the fix is to start a turn, not to fake a shell).
 * Under AUTH_BYPASS (e2e/perf) the ticket is minted in "mock" mode: the full
 * exchange runs hermetically and the client attaches its deterministic PTY.
 */
import { getAuthState } from "@/lib/auth/auth-state";
import { authBypassEnabled } from "@/lib/auth/config";
import { getDatabase } from "@/lib/db/client";
import { getSession } from "@/lib/db/sessions";
import {
	ensureTerminal,
	resolveLiveSandbox,
	TerminalUnsupportedError,
} from "@/lib/terminal/sandbox-terminal";
import { issueTerminalTicket } from "@/lib/terminal/tickets";

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

	if (authBypassEnabled()) {
		const ticket = await issueTerminalTicket(handle, {
			login: auth.user.login,
			sessionId: id,
			mode: "mock",
		});
		return Response.json({ state: "ready", mode: "mock", ...ticket });
	}

	const live = await resolveLiveSandbox(session);
	if (live.state === "none") {
		return Response.json({ state: "no-sandbox", reason: live.reason });
	}
	try {
		// Start ttyd now (idempotent) so redeem + connect stays fast and a
		// broken sandbox surfaces here, before a ticket is spent on it.
		await ensureTerminal(live.sandbox);
	} catch (error) {
		if (error instanceof TerminalUnsupportedError) {
			return Response.json({ state: "no-sandbox", reason: error.message });
		}
		const message =
			error instanceof Error ? error.message : "terminal setup failed";
		return Response.json({ error: message }, { status: 502 });
	}
	const ticket = await issueTerminalTicket(handle, {
		login: auth.user.login,
		sessionId: id,
		mode: "ttyd",
		sandboxName: live.sandbox.name,
	});
	return Response.json({ state: "ready", mode: "ttyd", ...ticket });
}
