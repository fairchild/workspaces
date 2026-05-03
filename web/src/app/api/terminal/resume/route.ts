import { getRegistry } from "@/lib/agent-runtime/provider-registry";
import { isSnapshotCapable } from "@/lib/agent-runtime/types";
import {
	getSessionForAgent,
	updateComputeInstance,
	updateSessionStatus,
} from "@/lib/agent-sessions";
import { authorizeRepoAccess, unauthorizedResponse } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";

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
	if (!session?.user) return unauthorizedResponse();

	const body = (await request.json()) as PostBody;
	if (!body.repo || !body.agentName) {
		return Response.json(
			{ error: "repo and agentName are required" },
			{ status: 400 },
		);
	}

	const unauthorized = await authorizeRepoAccess(session.user.id, body.repo);
	if (unauthorized) return unauthorized;

	const agentSession = await getSessionForAgent(
		session.user.id,
		body.repo,
		body.agentName,
	);
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

	const registry = await getRegistry();
	const provider = registry.get(
		agentSession.computeBackend as import("@/lib/types").ComputeBackendId,
	);
	if (!provider || !isSnapshotCapable(provider)) {
		return Response.json(
			{
				error: `Resume not supported for ${agentSession.computeBackend}`,
			},
			{ status: 501 },
		);
	}

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
