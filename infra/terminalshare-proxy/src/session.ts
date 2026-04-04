import type { Env } from "./index";

const RING_BUFFER_SIZE = 64 * 1024; // 64KB of output history for reconnection

interface SessionConfig {
	upstreamUrl: string;
	provider: "cloudflare" | "vercel";
	userToken: string;
}

/**
 * Durable Object that manages a single terminal session.
 *
 * Responsibilities:
 * 1. Accept WebSocket connections from browser clients (ghostty-web)
 * 2. Maintain a single upstream WebSocket to the sandbox PTY
 * 3. Bidirectional proxy: client ↔ upstream
 * 4. Ring buffer of recent output for reconnection replay
 * 5. Multiple clients can connect to the same session simultaneously
 */
export class TerminalSessionDO {
	private state: DurableObjectState;
	private config: SessionConfig | null = null;
	private upstream: WebSocket | null = null;
	private clients: Set<WebSocket> = new Set();
	private ringBuffer: string[] = [];
	private ringBufferSize = 0;
	private upstreamConnecting = false;

	constructor(state: DurableObjectState, _env: Env) {
		this.state = state;
		// Restore config from storage on wake
		this.state.blockConcurrencyWhile(async () => {
			this.config =
				(await this.state.storage.get<SessionConfig>("config")) ?? null;
		});
	}

	async fetch(request: Request): Promise<Response> {
		const url = new URL(request.url);

		// Internal: configure session
		if (url.pathname === "/configure" && request.method === "POST") {
			this.config = (await request.json()) as SessionConfig;
			await this.state.storage.put("config", this.config);
			return new Response("OK");
		}

		// WebSocket upgrade from browser client
		if (request.headers.get("Upgrade") === "websocket") {
			return this.handleClientWebSocket(request);
		}

		return new Response("Expected WebSocket", { status: 400 });
	}

	private handleClientWebSocket(_request: Request): Response {
		if (!this.config) {
			return new Response("Session not configured", { status: 404 });
		}

		const pair = new WebSocketPair();
		const [client, server] = [pair[0], pair[1]];

		this.state.acceptWebSocket(server);
		this.clients.add(server);

		// Replay ring buffer to new client
		for (const chunk of this.ringBuffer) {
			server.send(chunk);
		}

		// Ensure upstream is connected
		this.ensureUpstream();

		return new Response(null, { status: 101, webSocket: client });
	}

	webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): void {
		// Client → upstream (keystrokes, resize commands)
		if (this.upstream?.readyState === WebSocket.OPEN) {
			this.upstream.send(message);
		}
	}

	webSocketClose(ws: WebSocket): void {
		this.clients.delete(ws);
	}

	webSocketError(ws: WebSocket): void {
		this.clients.delete(ws);
	}

	private ensureUpstream(): void {
		if (
			this.upstream?.readyState === WebSocket.OPEN ||
			this.upstreamConnecting
		) {
			return;
		}
		if (!this.config) return;

		this.upstreamConnecting = true;
		const ws = new WebSocket(this.config.upstreamUrl);
		this.upstream = ws;

		ws.addEventListener("open", () => {
			this.upstreamConnecting = false;
		});

		ws.addEventListener("message", (event) => {
			const data =
				typeof event.data === "string"
					? event.data
					: new TextDecoder().decode(event.data as ArrayBuffer);

			// Buffer output for reconnection replay
			this.appendToRingBuffer(data);

			// Fan out to all connected clients
			for (const client of this.clients) {
				try {
					client.send(data);
				} catch {
					this.clients.delete(client);
				}
			}
		});

		ws.addEventListener("close", () => {
			this.upstream = null;
			this.upstreamConnecting = false;

			// Notify clients
			const msg = "\r\n\x1b[33mUpstream disconnected\x1b[0m\r\n";
			for (const client of this.clients) {
				try {
					client.send(msg);
				} catch {
					this.clients.delete(client);
				}
			}

			// Attempt reconnect if clients are still connected
			if (this.clients.size > 0) {
				setTimeout(() => this.ensureUpstream(), 2000);
			}
		});

		ws.addEventListener("error", () => {
			this.upstreamConnecting = false;
		});
	}

	private appendToRingBuffer(data: string): void {
		this.ringBuffer.push(data);
		this.ringBufferSize += data.length;

		// Evict oldest entries if over limit
		while (this.ringBufferSize > RING_BUFFER_SIZE && this.ringBuffer.length > 1) {
			const removed = this.ringBuffer.shift();
			if (removed) this.ringBufferSize -= removed.length;
		}
	}
}
