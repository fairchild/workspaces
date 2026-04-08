import { VercelSandboxProvider } from "@/lib/agent-runtime/vercel-sandbox";
import {
	getSessionForAgent,
	updateComputeInstance,
	updateSessionStatus,
} from "@/lib/agent-sessions";
import { getSession } from "@/lib/auth-server";
import { getUserRepos } from "@/lib/repos";

export const dynamic = "force-dynamic";
export const maxDuration = 300;

interface PostBody {
	repo: string;
	agentName: string;
}

/**
 * Resume a paused (snapshotted) terminal session by restoring its snapshot.
 * The session transitions from "snapshotted" back to "active" with a new
 * compute_instance_id from the restored sandbox.
 */
export async function POST(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session?.user) {
		return Response.json({ error: "unauthorized" }, { status: 401 });
	}

	const body = (await request.json()) as PostBody;
	if (!body.repo || !body.agentName) {
		return Response.json(
			{ error: "repo and agentName are required" },
			{ status: 400 },
		);
	}

	const userRepos = await getUserRepos(session.user.id);
	if (!userRepos.some((r) => `${r.owner}/${r.repo}` === body.repo)) {
		return Response.json(
			{ error: "repo not in your workspace" },
			{ status: 403 },
		);
	}

	const agentSession = await getSessionForAgent(body.repo, body.agentName);
	if (!agentSession) {
		return Response.json(
			{ error: "no session found for agent" },
			{ status: 404 },
		);
	}

	if (!agentSession.snapshotId) {
		return Response.json(
			{ error: "session has no snapshot to restore" },
			{ status: 409 },
		);
	}

	if (agentSession.computeBackend !== "vercel-sandbox") {
		return Response.json(
			{
				error: `resume not yet implemented for ${agentSession.computeBackend}`,
			},
			{ status: 501 },
		);
	}

	const provider = new VercelSandboxProvider();
	try {
		const restored = await provider.restoreSnapshot(agentSession.snapshotId);
		await updateComputeInstance(agentSession.id, restored.instanceId);
		await updateSessionStatus(agentSession.id, "active");
		return Response.json({
			sessionId: agentSession.id,
			sandboxId: restored.instanceId,
			agentName: body.agentName,
			status: "resumed",
		});
	} catch (err) {
		return Response.json(
			{
				error: `Failed to restore snapshot: ${
					err instanceof Error ? err.message : "unknown error"
				}`,
			},
			{ status: 500 },
		);
	}
}
