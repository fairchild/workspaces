export { TerminalSessionDO } from "./session";

export interface Env {
	TERMINAL_SESSION: DurableObjectNamespace;
	/** Shared secret for authenticating requests from the web app */
	PROXY_SECRET: string;
	/** Cloudflare Sandbox binding (when Sandbox SDK is configured) */
	// SANDBOX: unknown; // Uncomment when @cloudflare/sandbox is added
}

function checkAuth(request: Request, env: Env): boolean {
	return request.headers.get("Authorization") === `Bearer ${env.PROXY_SECRET}`;
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		const path = url.pathname;

		if (path === "/health") {
			return new Response("OK");
		}

		// --- Terminal WebSocket ---
		// /ws/:sessionId — browser connects here for terminal access
		const wsMatch = path.match(/^\/ws\/([a-zA-Z0-9_-]+)$/);
		if (wsMatch && request.headers.get("Upgrade") === "websocket") {
			return handleTerminalWebSocket(request, env, wsMatch[1]);
		}

		// --- Session management (called by Next.js backend) ---
		// All routes below require auth
		if (!checkAuth(request, env)) {
			return new Response("Unauthorized", { status: 401 });
		}

		// POST /sessions — register a terminal session (for any provider)
		if (path === "/sessions" && request.method === "POST") {
			return handleCreateSession(request, env);
		}

		// --- Sandbox lifecycle API (called by CloudflareSandboxProvider) ---

		// POST /sandbox/create — create a new Cloudflare sandbox
		if (path === "/sandbox/create" && request.method === "POST") {
			return handleSandboxCreate(request, env);
		}

		// POST /sandbox/restore — restore from backup
		if (path === "/sandbox/restore" && request.method === "POST") {
			return handleSandboxRestore(request, env);
		}

		// Sandbox instance routes: /sandbox/:instanceId/*
		const sandboxMatch = path.match(
			/^\/sandbox\/([a-zA-Z0-9_-]+)(\/.*)?$/,
		);
		if (sandboxMatch) {
			const instanceId = sandboxMatch[1];
			const subPath = sandboxMatch[2] ?? "";
			return handleSandboxRoute(request, env, instanceId, subPath);
		}

		return new Response("Not Found", { status: 404 });
	},
};

// ---------------------------------------------------------------------------
// Terminal WebSocket — browser connects here
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

// ---------------------------------------------------------------------------
// Session registration — called by Next.js backend for any provider
// ---------------------------------------------------------------------------

interface CreateSessionBody {
	sessionId: string;
	upstreamUrl: string;
	provider: "cloudflare" | "vercel";
	userToken?: string;
}

async function handleCreateSession(
	request: Request,
	env: Env,
): Promise<Response> {
	const body = (await request.json()) as CreateSessionBody;
	if (!body.sessionId || !body.upstreamUrl) {
		return Response.json(
			{ error: "sessionId and upstreamUrl required" },
			{ status: 400 },
		);
	}

	const doId = env.TERMINAL_SESSION.idFromName(body.sessionId);
	const stub = env.TERMINAL_SESSION.get(doId);

	await stub.fetch(
		new Request("https://internal/configure", {
			method: "POST",
			body: JSON.stringify({
				upstreamUrl: body.upstreamUrl,
				provider: body.provider ?? "vercel",
				userToken: body.userToken ?? "",
			}),
		}),
	);

	return Response.json({ sessionId: body.sessionId, status: "ready" });
}

// ---------------------------------------------------------------------------
// Sandbox lifecycle — Cloudflare Sandbox SDK operations
// ---------------------------------------------------------------------------

// These are placeholder implementations. When the Cloudflare Sandbox SDK
// (@cloudflare/sandbox) is added as a dependency and bound via wrangler.toml,
// they will use the real Sandbox API. For now, they return structured errors
// so the provider can detect unavailability gracefully.

async function handleSandboxCreate(
	_request: Request,
	_env: Env,
): Promise<Response> {
	// TODO: Implement with Cloudflare Sandbox SDK
	// const sandbox = getSandbox(env.SANDBOX, sessionId);
	// await sandbox.exec("git clone ...");
	// const terminalUrl = ... sandbox.terminal(request) ...
	return Response.json(
		{ error: "Cloudflare sandbox creation not yet implemented" },
		{ status: 501 },
	);
}

async function handleSandboxRestore(
	_request: Request,
	_env: Env,
): Promise<Response> {
	return Response.json(
		{ error: "Cloudflare sandbox restore not yet implemented" },
		{ status: 501 },
	);
}

async function handleSandboxRoute(
	request: Request,
	_env: Env,
	instanceId: string,
	subPath: string,
): Promise<Response> {
	const method = request.method;

	if (subPath === "/stream" && method === "GET") {
		return Response.json(
			{ error: `Stream not yet implemented for ${instanceId}` },
			{ status: 501 },
		);
	}

	if (subPath === "/message" && method === "POST") {
		return Response.json(
			{ error: `Message not yet implemented for ${instanceId}` },
			{ status: 501 },
		);
	}

	if (subPath === "/snapshot" && method === "POST") {
		return Response.json(
			{ error: `Snapshot not yet implemented for ${instanceId}` },
			{ status: 501 },
		);
	}

	if (subPath === "" && method === "DELETE") {
		return Response.json({ ok: true });
	}

	return new Response("Not Found", { status: 404 });
}
