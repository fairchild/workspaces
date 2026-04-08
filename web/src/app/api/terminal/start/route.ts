import crypto from "node:crypto";
import { VercelSandboxProvider } from "@/lib/agent-runtime/vercel-sandbox";
import { createSession, getSessionForAgent } from "@/lib/agent-sessions";
import { getSession } from "@/lib/auth-server";
import { getGitHubToken } from "@/lib/github";
import { getUserRepos } from "@/lib/repos";

export const dynamic = "force-dynamic";
export const maxDuration = 300;

interface PostBody {
	repo: string;
	agentName?: string;
	branch?: string;
}

/**
 * Start a terminal sandbox for a specific agent on a repo.
 *
 * If `agentName` is omitted, defaults to `DEFAULT_AGENT` env var, falling
 * back to "terminal" (a synthetic slot for ad-hoc shells not tied to any
 * agent persona).
 *
 * If a live session already exists for (repo, agentName), returns it
 * without creating a duplicate sandbox.
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

	const [owner, repoName] = body.repo.split("/");
	if (!owner || !repoName) {
		return Response.json(
			{ error: "repo must be owner/name format" },
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

	const agentName = body.agentName ?? process.env.DEFAULT_AGENT ?? "shell";

	// If a live session already exists for this (repo, agent), reuse it
	const existing = await getSessionForAgent(body.repo, agentName);
	if (existing?.computeInstanceId && existing.status !== "snapshotted") {
		return Response.json({
			sessionId: existing.id,
			sandboxId: existing.computeInstanceId,
			agentName,
			status: "reused",
		});
	}

	// Build clone URL — use token for private repos, fall back to public HTTPS
	let cloneUrl = `https://github.com/${body.repo}.git`;
	if (process.env.DEV_BYPASS_AUTH !== "1") {
		const token = await getGitHubToken(session.user.id).catch(() => null);
		if (token) {
			cloneUrl = `https://x-access-token:${token}@github.com/${body.repo}.git`;
		}
	}

	const provider = new VercelSandboxProvider();
	const availability = await provider.checkAvailability();
	if (!availability.available) {
		return Response.json(
			{ error: `Sandbox unavailable: ${availability.reason}` },
			{ status: 503 },
		);
	}

	let result: { instanceId: string; status: string };
	try {
		result = await provider.createTerminalSandbox({
			cloneUrl,
			branch: body.branch,
		});
	} catch (err) {
		return Response.json(
			{
				error: `Failed to create terminal sandbox: ${
					err instanceof Error ? err.message : "unknown error"
				}`,
			},
			{ status: 500 },
		);
	}

	const sessionId = crypto.randomUUID();
	const now = new Date().toISOString();
	await createSession({
		id: sessionId,
		repo: body.repo,
		agentName,
		computeBackend: "vercel-sandbox",
		computeInstanceId: result.instanceId,
		snapshotId: null,
		claudeSessionId: null,
		threadId: `terminal:${session.user.id}:${agentName}:${Date.now()}`,
		discussionId: null,
		status: "active",
		createdAt: now,
		lastActivityAt: now,
	});

	return Response.json({
		sessionId,
		sandboxId: result.instanceId,
		agentName,
		status: "ready",
	});
}
