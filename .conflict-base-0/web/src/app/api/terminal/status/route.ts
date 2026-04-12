import { getRegistry } from "@/lib/agent-runtime/provider-registry";
import {
	type SandboxState,
	isTerminalCapable,
} from "@/lib/agent-runtime/types";
import { getSessionsForRepo, updateSessionStatus } from "@/lib/agent-sessions";
import { getSession } from "@/lib/auth-server";
import { getUserRepos } from "@/lib/repos";
import type { AgentSession, ComputeBackendId } from "@/lib/types";

export const dynamic = "force-dynamic";

export type TerminalSessionState = "running" | "paused";

export interface TerminalSessionInfo {
	agentName: string;
	state: TerminalSessionState;
	sandboxId: string;
	provider: string;
	terminalUrl?: string;
}

async function resolveState(
	computeBackend: string,
	instanceId: string,
): Promise<SandboxState | null> {
	const registry = await getRegistry();
	const provider = registry.get(computeBackend as ComputeBackendId);
	if (!provider || !isTerminalCapable(provider)) return null;
	return provider.resolveSandboxState(instanceId);
}

/**
 * Resolve a DB session into a TerminalSessionInfo for the UI.
 * Returns null if the sandbox is dead AND the DB says it should be alive
 * (in which case we reconcile it to "completed" and drop it from the list).
 */
async function resolveSession(
	session: AgentSession,
): Promise<TerminalSessionInfo | null> {
	if (!session.computeInstanceId) return null;

	const state = await resolveState(
		session.computeBackend,
		session.computeInstanceId,
	);

	// Unknown backend — trust the DB
	if (state === null) {
		return {
			agentName: session.agentName,
			state: session.status === "snapshotted" ? "paused" : "running",
			sandboxId: session.computeInstanceId,
			provider: session.computeBackend,
		};
	}

	if (!state.alive) {
		// Snapshotted sessions are expected to not be running — they're paused
		if (session.status === "snapshotted") {
			return {
				agentName: session.agentName,
				state: "paused",
				sandboxId: session.computeInstanceId,
				provider: session.computeBackend,
			};
		}
		// Active in DB but actually dead → reconcile
		await updateSessionStatus(session.id, "completed").catch((err) => {
			console.warn("[terminal/status] reconcile update failed:", err);
		});
		return null;
	}

	return {
		agentName: session.agentName,
		state: "running",
		sandboxId: session.computeInstanceId,
		provider: session.computeBackend,
		terminalUrl: state.terminalUrl,
	};
}

export async function GET(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session?.user) {
		return Response.json({ error: "unauthorized" }, { status: 401 });
	}

	const url = new URL(request.url);
	const repo = url.searchParams.get("repo");
	if (!repo) {
		return Response.json({ error: "repo is required" }, { status: 400 });
	}

	const userRepos = await getUserRepos(session.user.id);
	if (!userRepos.some((r) => `${r.owner}/${r.repo}` === repo)) {
		return Response.json(
			{ error: "repo not in your workspace" },
			{ status: 403 },
		);
	}

	const dbSessions = await getSessionsForRepo(repo);
	const resolved = await Promise.all(dbSessions.map(resolveSession));
	const sessions = resolved.filter((s): s is TerminalSessionInfo => s !== null);

	return Response.json({ sessions });
}
