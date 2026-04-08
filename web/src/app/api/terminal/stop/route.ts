import {
	getActiveSessionForRepo,
	updateSessionStatus,
} from "@/lib/agent-sessions";
import { getSession } from "@/lib/auth-server";
import { getUserRepos } from "@/lib/repos";
import { Sandbox } from "@vercel/sandbox";

export const dynamic = "force-dynamic";

function getCredentials() {
	return {
		token: process.env.VERCEL_TOKEN,
		teamId: process.env.VERCEL_TEAM_ID,
		projectId: process.env.VERCEL_PROJECT_ID,
	};
}

interface PostBody {
	repo: string;
}

/**
 * Stop the active terminal session for a repo. Marks the session completed
 * and tells Vercel to stop the sandbox so we don't pay for idle time.
 */
export async function POST(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session?.user) {
		return Response.json({ error: "unauthorized" }, { status: 401 });
	}

	const body = (await request.json()) as PostBody;
	if (!body.repo) {
		return Response.json({ error: "repo is required" }, { status: 400 });
	}

	const userRepos = await getUserRepos(session.user.id);
	if (!userRepos.some((r) => `${r.owner}/${r.repo}` === body.repo)) {
		return Response.json(
			{ error: "repo not in your workspace" },
			{ status: 403 },
		);
	}

	const agentSession = await getActiveSessionForRepo(body.repo);
	if (!agentSession?.computeInstanceId) {
		return Response.json({ stopped: false, reason: "no active session" });
	}

	// Best-effort sandbox stop (don't fail if already dead)
	try {
		const sandbox = await Sandbox.get({
			sandboxId: agentSession.computeInstanceId,
			...getCredentials(),
		});
		await sandbox.stop();
	} catch {
		// sandbox already gone
	}

	await updateSessionStatus(agentSession.id, "completed");

	return Response.json({ stopped: true, sessionId: agentSession.id });
}
