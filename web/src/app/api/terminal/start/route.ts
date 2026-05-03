import crypto from "node:crypto";
import { ALLOWED_AGENT_LOGINS } from "@/lib/agent-runtime/config";
import { getRegistry } from "@/lib/agent-runtime/provider-registry";
import { isTerminalCapable } from "@/lib/agent-runtime/types";
import { createSession, getSessionForAgent } from "@/lib/agent-sessions";
import { authorizeRepoAccess, unauthorizedResponse } from "@/lib/api-auth";
import { getDevBypassToken, getSession } from "@/lib/auth-server";
import { fetchGitHubLogin, getGitHubToken } from "@/lib/github";

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
	if (!session?.user) return unauthorizedResponse();

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

	const unauthorized = await authorizeRepoAccess(session.user.id, body.repo);
	if (unauthorized) return unauthorized;

	let authToken: string | undefined;
	let login: string;
	const bypass = getDevBypassToken();
	if (bypass) {
		login = "fairchild";
	} else {
		const token = await getGitHubToken(session.user.id).catch(() => null);
		if (!token) {
			return Response.json(
				{ error: "GitHub token not found" },
				{ status: 403 },
			);
		}
		authToken = token;
		login = await fetchGitHubLogin(token);
	}

	if (!ALLOWED_AGENT_LOGINS.has(login)) {
		return Response.json(
			{ error: "Terminal sessions are not yet available for your account" },
			{ status: 403 },
		);
	}

	const agentName = body.agentName ?? process.env.DEFAULT_AGENT ?? "shell";

	// If a live session already exists for this (repo, agent), reuse it
	const existing = await getSessionForAgent(
		session.user.id,
		body.repo,
		agentName,
	);
	if (existing?.computeInstanceId && existing.status !== "snapshotted") {
		return Response.json({
			sessionId: existing.id,
			sandboxId: existing.computeInstanceId,
			agentName,
			status: "reused",
		});
	}

	// Keep the clone URL token-free so it cannot persist in .git/config.
	const cloneUrl = `https://github.com/${body.repo}.git`;

	const registry = await getRegistry();

	// Terminal sessions need a PTY-capable provider, which may differ from the
	// default (e.g. default=managed-agents for chat, but terminals need Vercel).
	const defaultProvider = registry.getDefault();
	const provider = isTerminalCapable(defaultProvider)
		? defaultProvider
		: registry.all().find(isTerminalCapable);

	if (!provider) {
		return Response.json(
			{
				error: "No terminal-capable provider is configured",
			},
			{ status: 501 },
		);
	}

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
			authToken,
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
		userId: session.user.id,
		repo: body.repo,
		agentName,
		computeBackend: provider.descriptor.id,
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
