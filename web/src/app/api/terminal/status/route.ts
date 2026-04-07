import {
	getActiveSessionForRepo,
	updateSessionStatus,
} from "@/lib/agent-sessions";
import { getSession } from "@/lib/auth-server";
import { getUserRepos } from "@/lib/repos";

export const dynamic = "force-dynamic";

type SandboxState = { alive: false } | { alive: true; terminalUrl?: string };

/** Dynamic provider loader — keeps cold-start cost low. */
async function resolveState(
	computeBackend: string,
	instanceId: string,
): Promise<SandboxState | null> {
	if (computeBackend === "cloudflare-sandbox") {
		const m = await import("@/lib/agent-runtime/cloudflare-sandbox");
		return m.resolveSandboxState(instanceId);
	}
	if (computeBackend === "vercel-sandbox") {
		const m = await import("@/lib/agent-runtime/vercel-sandbox");
		return m.resolveSandboxState(instanceId);
	}
	return null; // unknown backend — no reconciliation
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

	const agentSession = await getActiveSessionForRepo(repo);
	if (!agentSession?.computeInstanceId) {
		return Response.json({ connected: false });
	}

	const state = await resolveState(
		agentSession.computeBackend,
		agentSession.computeInstanceId,
	);

	// Unknown backend — trust the DB, report connected without terminalUrl
	if (state === null) {
		return Response.json({
			connected: true,
			sandboxId: agentSession.computeInstanceId,
			agentName: agentSession.agentName,
			provider: agentSession.computeBackend,
		});
	}

	// Reconcile: if the sandbox is dead, mark the session completed
	// and report disconnected so the UI shows the correct empty state.
	if (!state.alive) {
		// Best-effort — don't fail the endpoint if the DB write blips
		await updateSessionStatus(agentSession.id, "completed").catch((err) => {
			console.warn("[terminal/status] reconcile update failed:", err);
		});
		return Response.json({ connected: false });
	}

	return Response.json({
		connected: true,
		sandboxId: agentSession.computeInstanceId,
		agentName: agentSession.agentName,
		provider: agentSession.computeBackend,
		terminalUrl: state.terminalUrl,
	});
}
