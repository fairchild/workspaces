import { getActiveSessionForRepo } from "@/lib/agent-sessions";
import { getSession } from "@/lib/auth-server";
import { getUserRepos } from "@/lib/repos";

export const dynamic = "force-dynamic";

/**
 * Resolve the terminal WebSocket URL for a sandbox session.
 * - Vercel sandbox: direct connection to ttyd on sandbox.domain(7681)
 * - Cloudflare sandbox: WebSocket via TerminalShare Worker
 */
async function resolveTerminalUrl(
	computeBackend: string,
	instanceId: string,
): Promise<string | undefined> {
	if (computeBackend === "cloudflare-sandbox") {
		const { getTerminalUrl } = await import(
			"@/lib/agent-runtime/cloudflare-sandbox"
		);
		return getTerminalUrl(instanceId) ?? undefined;
	}

	if (computeBackend === "vercel-sandbox") {
		const { getTerminalUrl } = await import(
			"@/lib/agent-runtime/vercel-sandbox"
		);
		return getTerminalUrl(instanceId) ?? undefined;
	}

	return undefined;
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

	const terminalUrl = await resolveTerminalUrl(
		agentSession.computeBackend,
		agentSession.computeInstanceId,
	);

	return Response.json({
		connected: true,
		sandboxId: agentSession.computeInstanceId,
		agentName: agentSession.agentName,
		provider: agentSession.computeBackend,
		terminalUrl,
	});
}
