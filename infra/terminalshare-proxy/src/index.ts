export { TerminalSessionDO } from "./session";

export interface Env {
	TERMINAL_SESSION: DurableObjectNamespace;
	/** Shared secret for authenticating requests from the web app */
	PROXY_SECRET: string;
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		const path = url.pathname;

		if (path === "/health") {
			return new Response("OK");
		}

		// POST /sessions — register a new terminal session
		// Called by the web app backend when a sandbox with a terminal becomes available
		if (path === "/sessions" && request.method === "POST") {
			return handleCreateSession(request, env);
		}

		// WebSocket /ws/:sessionId — browser connects here
		const wsMatch = path.match(/^\/ws\/([a-zA-Z0-9_-]+)$/);
		if (wsMatch && request.headers.get("Upgrade") === "websocket") {
			return handleTerminalWebSocket(request, env, wsMatch[1]);
		}

		return new Response("Not Found", { status: 404 });
	},
};

// ---------------------------------------------------------------------------
// Create session — called by web app backend
// ---------------------------------------------------------------------------

interface CreateSessionBody {
	sessionId: string;
	/** WebSocket URL to the upstream PTY (sandbox port or Cloudflare terminal) */
	upstreamUrl: string;
	/** Which sandbox provider */
	provider: "cloudflare" | "vercel";
	/** Auth token for the session owner */
	userToken: string;
}

async function handleCreateSession(
	request: Request,
	env: Env,
): Promise<Response> {
	const auth = request.headers.get("Authorization");
	if (auth !== `Bearer ${env.PROXY_SECRET}`) {
		return new Response("Unauthorized", { status: 401 });
	}

	const body = (await request.json()) as CreateSessionBody;
	if (!body.sessionId || !body.upstreamUrl) {
		return new Response("sessionId and upstreamUrl required", { status: 400 });
	}

	// Store session config in the Durable Object
	const doId = env.TERMINAL_SESSION.idFromName(body.sessionId);
	const stub = env.TERMINAL_SESSION.get(doId);

	const configReq = new Request("https://internal/configure", {
		method: "POST",
		body: JSON.stringify({
			upstreamUrl: body.upstreamUrl,
			provider: body.provider ?? "vercel",
			userToken: body.userToken,
		}),
	});
	await stub.fetch(configReq);

	return Response.json({ sessionId: body.sessionId, status: "ready" });
}

// ---------------------------------------------------------------------------
// WebSocket — browser terminal connects here
// ---------------------------------------------------------------------------

async function handleTerminalWebSocket(
	request: Request,
	env: Env,
	sessionId: string,
): Promise<Response> {
	const doId = env.TERMINAL_SESSION.idFromName(sessionId);
	const stub = env.TERMINAL_SESSION.get(doId);
	return stub.fetch(request);
}
