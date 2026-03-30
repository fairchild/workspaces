import { getSessionManager } from "@/lib/agent-runtime/session-manager";
import { getSession } from "@/lib/auth-server";
import { getGitHubToken } from "@/lib/github";
import { getUserRepos } from "@/lib/repos";

export const dynamic = "force-dynamic";
export const maxDuration = 300; // 5 min for Vercel Pro

interface PostBody {
	repo: string;
	agentName: string;
	message: string;
	threadId?: string;
	discussionId?: string;
}

export async function POST(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session?.user) {
		return Response.json({ error: "unauthorized" }, { status: 401 });
	}

	const body = (await request.json()) as PostBody;
	if (!body.repo || !body.agentName || !body.message) {
		return Response.json(
			{ error: "repo, agentName, and message are required" },
			{ status: 400 },
		);
	}

	const [owner, repo] = body.repo.split("/");
	if (!owner || !repo) {
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

	const token = await getGitHubToken(session.user.id);
	if (!token) {
		return Response.json({ error: "GitHub token not found" }, { status: 403 });
	}

	const manager = getSessionManager();
	const encoder = new TextEncoder();

	const stream = new ReadableStream({
		async start(controller) {
			try {
				for await (const chunk of manager.handleMention({
					repo: body.repo,
					agentName: body.agentName,
					message: body.message,
					userId: session.user.id,
					githubToken: token,
					threadId: body.threadId,
					discussionId: body.discussionId,
				})) {
					const event = `data: ${JSON.stringify(chunk)}\n\n`;
					controller.enqueue(encoder.encode(event));
				}
			} catch (err) {
				const errorEvent = `data: ${JSON.stringify({
					type: "error",
					content: err instanceof Error ? err.message : "Stream error",
				})}\n\n`;
				controller.enqueue(encoder.encode(errorEvent));
			} finally {
				controller.close();
			}
		},
	});

	return new Response(stream, {
		headers: {
			"Content-Type": "text/event-stream",
			"Cache-Control": "no-cache",
			Connection: "keep-alive",
		},
	});
}
