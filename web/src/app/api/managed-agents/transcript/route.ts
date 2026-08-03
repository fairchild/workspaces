import { getSessionByInstanceId } from "@/lib/agent-sessions";
import { authorizeRepoAccess } from "@/lib/api-auth";
import { getSession } from "@/lib/auth-server";
import Anthropic from "@anthropic-ai/sdk";
import type { BetaManagedAgentsStreamSessionEvents } from "@anthropic-ai/sdk/resources/beta/sessions/events";

export const dynamic = "force-dynamic";
// Backstop: Fluid Compute bills wall-clock while this function is warm, so an
// orphaned stream must not run indefinitely. Clients reconnect if still live.
export const maxDuration = 300;

/**
 * SSE endpoint that streams a Managed Agents session's `agent.tool_use` and
 * `agent.tool_result` events as compact JSON lines, consumed by the
 * `TranscriptTerminal` client component. Read-only: there is no way to
 * drive the container from this route. Finished sessions get an `end`
 * sentinel instead of a live tail so the client stops reconnecting.
 */
export async function GET(request: Request): Promise<Response> {
	const authed = await getSession();
	if (!authed?.user) {
		return new Response("unauthorized", { status: 401 });
	}
	const sessionId = new URL(request.url).searchParams.get("sessionId");
	if (!sessionId) {
		return new Response("sessionId required", { status: 400 });
	}

	const agentSession = await getSessionByInstanceId(authed.user.id, sessionId);
	const repo = agentSession?.repo ?? null;
	if (!repo) {
		return new Response("session not found", { status: 404 });
	}
	const unauthorized = await authorizeRepoAccess(authed.user.id, repo);
	if (unauthorized) return unauthorized;

	if (!process.env.ANTHROPIC_API_KEY) {
		return new Response("ANTHROPIC_API_KEY not set", { status: 503 });
	}

	const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
	const encoder = new TextEncoder();

	const stream = new ReadableStream<Uint8Array>({
		async start(controller) {
			const send = (data: unknown) => {
				controller.enqueue(encoder.encode(`data: ${JSON.stringify(data)}\n\n`));
			};

			let closed = false;
			const onAbort = () => {
				closed = true;
				try {
					controller.close();
				} catch {
					// already closed
				}
			};
			request.signal.addEventListener("abort", onAbort);

			// Tell the client no further events will ever arrive, so it closes
			// its EventSource instead of auto-reconnecting forever.
			const sendEnd = () => {
				if (closed) return;
				controller.enqueue(encoder.encode("event: end\ndata: {}\n\n"));
			};

			// Live-tailing only makes sense while the session can still emit
			// events. Chat sessions stay tailable while idle — a follow-up user
			// turn can produce more tool calls on the same session.
			const shouldLiveTail = async (): Promise<boolean> => {
				try {
					const session = await client.beta.sessions.retrieve(sessionId);
					if (session.status === "terminated") return false;
				} catch {
					return false;
				}
				return true;
			};

			try {
				// Backfill existing history first so the user sees prior calls
				// immediately when they open the tab.
				for await (const event of client.beta.sessions.events.list(sessionId, {
					order: "asc",
				})) {
					if (closed) return;
					const line = toTranscriptLine(
						event as BetaManagedAgentsStreamSessionEvents,
					);
					if (line) send(line);
				}

				if (!(await shouldLiveTail())) {
					sendEnd();
					return;
				}

				const live = await client.beta.sessions.events.stream(sessionId);
				for await (const event of live) {
					if (closed) return;
					const line = toTranscriptLine(event);
					if (line) send(line);
				}
			} catch (err) {
				if (!closed) {
					send({
						key: `error-${Date.now()}`,
						kind: "error",
						text: err instanceof Error ? err.message : String(err),
					});
				}
			} finally {
				request.signal.removeEventListener("abort", onAbort);
				if (!closed) {
					try {
						controller.close();
					} catch {
						// already closed
					}
				}
			}
		},
	});

	return new Response(stream, {
		headers: {
			"Content-Type": "text/event-stream",
			"Cache-Control": "no-cache, no-transform",
			Connection: "keep-alive",
		},
	});
}

interface TranscriptLine {
	key: string;
	kind: "command" | "result" | "status" | "error";
	tool?: string;
	text: string;
}

function toTranscriptLine(
	event: BetaManagedAgentsStreamSessionEvents,
): TranscriptLine | null {
	if (event.type === "agent.tool_use") {
		const input = event.input as Record<string, unknown> | undefined;
		const text =
			event.name === "bash"
				? String(input?.command ?? "")
				: JSON.stringify(input ?? {});
		return {
			key: event.id,
			kind: "command",
			tool: event.name,
			text,
		};
	}
	if (event.type === "agent.tool_result") {
		const parts: string[] = [];
		for (const block of event.content ?? []) {
			if (block && (block as { type?: string }).type === "text") {
				parts.push((block as { text?: string }).text ?? "");
			}
		}
		const text = parts.join("");
		if (!text) return null;
		return { key: event.id, kind: "result", text };
	}
	if (event.type === "session.error") {
		const err = event.error as { message?: string } | undefined;
		return {
			key: event.id,
			kind: "error",
			text: err?.message ?? "session.error",
		};
	}
	return null;
}
