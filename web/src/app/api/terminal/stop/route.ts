import { getRegistry } from "@/lib/agent-runtime/provider-registry";
import { isTerminalCapable } from "@/lib/agent-runtime/types";
import { getSessionForAgent, updateSessionStatus } from "@/lib/agent-sessions";
import { authorizeRepoAccess, unauthorizedResponse } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";
import type { ComputeBackendId } from "@/lib/types";

export const dynamic = "force-dynamic";

interface PostBody {
	repo: string;
	agentName?: string;
}

/**
 * Stop the active terminal session for (repo, agentName). If agentName is
 * omitted, defaults to the DEFAULT_AGENT env var fallback used by start.
 */
export async function POST(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session?.user) return unauthorizedResponse();

	const body = (await request.json()) as PostBody;
	if (!body.repo) {
		return Response.json({ error: "repo is required" }, { status: 400 });
	}

	const unauthorized = await authorizeRepoAccess(session.user.id, body.repo);
	if (unauthorized) return unauthorized;

	const agentName = body.agentName ?? process.env.DEFAULT_AGENT ?? "shell";

	const agentSession = await getSessionForAgent(
		session.user.id,
		body.repo,
		agentName,
	);
	if (!agentSession?.computeInstanceId) {
		return Response.json({ stopped: false, reason: "no active session" });
	}

	// Best-effort sandbox stop (don't fail if already dead).
	// Uses stopSandbox (cross-process safe) rather than destroySandbox
	// (in-memory only), since API routes run in different serverless instances.
	try {
		const registry = await getRegistry();
		const provider = registry.get(
			agentSession.computeBackend as ComputeBackendId,
		);
		if (provider && isTerminalCapable(provider)) {
			await provider.stopSandbox(agentSession.computeInstanceId);
		}
	} catch {
		// sandbox already gone
	}

	await updateSessionStatus(agentSession.id, "completed");

	return Response.json({
		stopped: true,
		sessionId: agentSession.id,
		agentName,
	});
}
