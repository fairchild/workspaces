import { getActiveSessionForRepo } from "@/lib/agent-sessions";
import { getSession } from "@/lib/auth-server";
import { getUserRepos } from "@/lib/repos";
import { Sandbox } from "@vercel/sandbox";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

function getCredentials() {
	return {
		token: process.env.VERCEL_TOKEN,
		teamId: process.env.VERCEL_TEAM_ID,
		projectId: process.env.VERCEL_PROJECT_ID,
	};
}

interface PostBody {
	repo: string;
	command: string;
}

export async function POST(request: Request): Promise<Response> {
	const session = await getSession();
	if (!session?.user) {
		return Response.json({ error: "unauthorized" }, { status: 401 });
	}

	const body = (await request.json()) as PostBody;
	if (!body.repo || !body.command) {
		return Response.json(
			{ error: "repo and command are required" },
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

	const agentSession = await getActiveSessionForRepo(body.repo);
	if (!agentSession?.computeInstanceId) {
		return Response.json(
			{ error: "No active sandbox for this repo" },
			{ status: 404 },
		);
	}

	let sandbox: Sandbox;
	try {
		sandbox = await Sandbox.get({
			sandboxId: agentSession.computeInstanceId,
			...getCredentials(),
		});
	} catch {
		return Response.json(
			{ error: "Sandbox is no longer available" },
			{ status: 410 },
		);
	}

	const encoder = new TextEncoder();

	const stream = new ReadableStream({
		async start(controller) {
			try {
				const cmd = await sandbox.runCommand({
					cmd: "bash",
					args: ["-c", body.command],
					cwd: "/vercel/sandbox/repo",
					detached: true,
				});

				for await (const log of cmd.logs()) {
					const event = `data: ${JSON.stringify({
						stream: log.stream,
						data: log.data,
					})}\n\n`;
					controller.enqueue(encoder.encode(event));
				}

				const finished = await cmd.wait();
				controller.enqueue(
					encoder.encode(
						`data: ${JSON.stringify({ type: "exit", exitCode: finished.exitCode })}\n\n`,
					),
				);
			} catch (err) {
				controller.enqueue(
					encoder.encode(
						`data: ${JSON.stringify({
							type: "error",
							data: err instanceof Error ? err.message : "Command failed",
						})}\n\n`,
					),
				);
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
