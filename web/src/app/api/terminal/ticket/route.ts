import { getRegistry } from "@/lib/agent-runtime/provider-registry";
import { isTerminalCapable } from "@/lib/agent-runtime/types";
import { getSession } from "@/lib/agent-sessions";
import { authorizeRepoAccess, unauthorizedResponse } from "@/lib/api-auth";
import { getSession as getAuthSession } from "@/lib/auth-server";
import {
	consumeTerminalTicket,
	issueTerminalTicket,
} from "@/lib/terminal-tickets";
import type { ComputeBackendId } from "@/lib/types";

export const dynamic = "force-dynamic";

interface TicketRequestBody {
	repo?: string;
	sessionId?: string;
}

function ticketError(reason: string): Response {
	switch (reason) {
		case "expired":
		case "redeemed":
			return Response.json(
				{ error: "terminal ticket expired" },
				{ status: 410 },
			);
		default:
			return Response.json(
				{ error: "terminal ticket denied" },
				{ status: 403 },
			);
	}
}

async function resolveLiveTerminalUrl(params: {
	userId: string;
	repo: string;
	sessionId: string;
	computeInstanceId?: string;
	computeBackend?: string;
}): Promise<
	| {
			ok: true;
			terminalUrl: string;
			computeInstanceId: string;
			computeBackend: string;
	  }
	| { ok: false; status: number; error: string }
> {
	const session = await getSession(params.sessionId);
	if (
		!session ||
		session.userId !== params.userId ||
		session.repo !== params.repo
	) {
		return { ok: false, status: 403, error: "terminal session denied" };
	}
	if (
		params.computeInstanceId &&
		session.computeInstanceId !== params.computeInstanceId
	) {
		return { ok: false, status: 409, error: "terminal session changed" };
	}
	if (
		params.computeBackend &&
		session.computeBackend !== params.computeBackend
	) {
		return { ok: false, status: 409, error: "terminal provider changed" };
	}
	if (
		!session.computeInstanceId ||
		!["active", "streaming"].includes(session.status)
	) {
		return { ok: false, status: 409, error: "terminal session is not running" };
	}

	const registry = await getRegistry();
	const provider = registry.get(session.computeBackend as ComputeBackendId);
	if (!provider || !isTerminalCapable(provider)) {
		return { ok: false, status: 501, error: "terminal provider unavailable" };
	}

	const state = await provider.resolveSandboxState(session.computeInstanceId);
	if (!state.alive || !state.terminalUrl) {
		return { ok: false, status: 409, error: "terminal sandbox is not running" };
	}

	return {
		ok: true,
		terminalUrl: state.terminalUrl,
		computeInstanceId: session.computeInstanceId,
		computeBackend: session.computeBackend,
	};
}

export async function POST(request: Request): Promise<Response> {
	const session = await getAuthSession();
	if (!session?.user) return unauthorizedResponse();

	const body = (await request.json()) as TicketRequestBody;
	if (!body.repo || !body.sessionId) {
		return Response.json(
			{ error: "repo and sessionId are required" },
			{ status: 400 },
		);
	}

	const unauthorized = await authorizeRepoAccess(session.user.id, body.repo);
	if (unauthorized) return unauthorized;

	const terminal = await resolveLiveTerminalUrl({
		userId: session.user.id,
		repo: body.repo,
		sessionId: body.sessionId,
	});
	if (!terminal.ok) {
		return Response.json(
			{ error: terminal.error },
			{ status: terminal.status },
		);
	}

	const ticket = await issueTerminalTicket({
		userId: session.user.id,
		repo: body.repo,
		sessionId: body.sessionId,
		computeInstanceId: terminal.computeInstanceId,
		computeBackend: terminal.computeBackend,
	});

	return Response.json(ticket);
}

export async function GET(request: Request): Promise<Response> {
	const session = await getAuthSession();
	if (!session?.user) return unauthorizedResponse();

	const url = new URL(request.url);
	const ticket = url.searchParams.get("ticket");
	if (!ticket) {
		return Response.json({ error: "ticket is required" }, { status: 400 });
	}

	const consumed = await consumeTerminalTicket(ticket, session.user.id);
	if (!consumed.ok) return ticketError(consumed.reason);

	const unauthorized = await authorizeRepoAccess(
		session.user.id,
		consumed.ticket.repo,
	);
	if (unauthorized) return unauthorized;

	const terminal = await resolveLiveTerminalUrl({
		userId: session.user.id,
		repo: consumed.ticket.repo,
		sessionId: consumed.ticket.sessionId,
		computeInstanceId: consumed.ticket.computeInstanceId,
		computeBackend: consumed.ticket.computeBackend,
	});
	if (!terminal.ok) {
		return Response.json(
			{ error: terminal.error },
			{ status: terminal.status },
		);
	}

	return Response.json({ terminalUrl: terminal.terminalUrl });
}
