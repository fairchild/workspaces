import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SandboxRequest, StreamChunk } from "../types";

// Mock fetch globally
const mockFetch = vi.fn();
vi.stubGlobal("fetch", mockFetch);

// Import after mocking
import { AnthropicManagedProvider } from "../anthropic-managed";

function jsonResponse(data: unknown, status = 200): Response {
	return new Response(JSON.stringify(data), {
		status,
		headers: { "content-type": "application/json" },
	});
}

/** Build an SSE-formatted response from event JSON objects. */
function sseResponse(events: string[]): Response {
	const body = events.map((e) => `data: ${e}\n`).join("\n");
	return new Response(body, {
		status: 200,
		headers: { "content-type": "text/event-stream" },
	});
}

/** Set up mocks for the 4-call createSandbox flow: environment, agent, session, send. */
function mockCreateSandboxFlow(sessionId = "session-1") {
	mockFetch
		.mockResolvedValueOnce(jsonResponse({ id: "env-1" }))
		.mockResolvedValueOnce(jsonResponse({ id: "agent-1", version: 1 }))
		.mockResolvedValueOnce(jsonResponse({ id: sessionId }))
		.mockResolvedValueOnce(jsonResponse({}));
}

function makeRequest(overrides: Partial<SandboxRequest> = {}): SandboxRequest {
	return {
		sessionId: "sess-1",
		repo: "acme/app",
		cloneUrl: "https://github.com/acme/app.git",
		readOnly: true,
		systemPrompt: "You are a helpful assistant.",
		message: "What does this repo do?",
		tools: "conversational",
		...overrides,
	};
}

async function collect(
	gen: AsyncGenerator<StreamChunk>,
): Promise<StreamChunk[]> {
	const chunks: StreamChunk[] = [];
	for await (const c of gen) chunks.push(c);
	return chunks;
}

describe("AnthropicManagedProvider", () => {
	let provider: AnthropicManagedProvider;

	beforeEach(() => {
		vi.clearAllMocks();
		// Fresh instance each test — caches are instance-level
		provider = new AnthropicManagedProvider();
		process.env.ANTHROPIC_API_KEY = "test-key";
		process.env.ANTHROPIC_MANAGED_AGENTS = "1";
	});

	afterEach(() => {
		process.env.ANTHROPIC_API_KEY = "";
		process.env.ANTHROPIC_MANAGED_AGENTS = "";
	});

	describe("descriptor", () => {
		it("has correct id and capabilities", () => {
			expect(provider.descriptor.id).toBe("anthropic-managed");
			expect(provider.descriptor.supportsSnapshot).toBe(false);
			expect(provider.descriptor.supportsStreaming).toBe(true);
		});
	});

	describe("checkAvailability", () => {
		it("returns unavailable when API key missing", async () => {
			process.env.ANTHROPIC_API_KEY = "";
			const result = await provider.checkAvailability();
			expect(result.available).toBe(false);
			expect(result.reason).toContain("ANTHROPIC_API_KEY");
		});

		it("returns unavailable when feature flag not set", async () => {
			process.env.ANTHROPIC_MANAGED_AGENTS = "";
			const result = await provider.checkAvailability();
			expect(result.available).toBe(false);
			expect(result.reason).toContain("ANTHROPIC_MANAGED_AGENTS");
		});

		it("returns available when configured", async () => {
			const result = await provider.checkAvailability();
			expect(result.available).toBe(true);
		});
	});

	describe("createSandbox", () => {
		it("creates environment, agent, session, and sends initial message", async () => {
			mockCreateSandboxFlow("session-1");

			const result = await provider.createSandbox(makeRequest());

			expect(result.instanceId).toBe("session-1");
			expect(result.status).toBe("ready");
			expect(mockFetch).toHaveBeenCalledTimes(4);

			// Verify environment creation
			const envCall = mockFetch.mock.calls[0];
			expect(envCall[0]).toContain("/environments");
			expect(JSON.parse(envCall[1].body)).toMatchObject({
				name: "workspaces-default",
				config: { type: "cloud" },
			});

			// Verify agent creation
			const agentCall = mockFetch.mock.calls[1];
			expect(agentCall[0]).toContain("/agents");
			expect(JSON.parse(agentCall[1].body)).toMatchObject({
				model: "claude-sonnet-4-6",
				tools: [{ type: "agent_toolset_20260401" }],
			});

			// Verify session creation references agent and environment
			const sessionCall = mockFetch.mock.calls[2];
			expect(JSON.parse(sessionCall[1].body)).toMatchObject({
				agent: "agent-1",
				environment_id: "env-1",
			});

			// Verify initial message includes clone instructions
			const sendCall = mockFetch.mock.calls[3];
			const sendBody = JSON.parse(sendCall[1].body);
			expect(sendBody.events[0].type).toBe("user.message");
			expect(sendBody.events[0].content[0].text).toContain("git clone");
		});

		it("includes branch in clone instructions when provided", async () => {
			mockCreateSandboxFlow("session-2");

			await provider.createSandbox(makeRequest({ branch: "feat/new" }));

			const sendBody = JSON.parse(mockFetch.mock.calls[3][1].body);
			expect(sendBody.events[0].content[0].text).toContain("-b feat/new");
		});

		it("throws on session creation failure", async () => {
			mockFetch
				.mockResolvedValueOnce(jsonResponse({ id: "env-1" }))
				.mockResolvedValueOnce(jsonResponse({ id: "agent-1", version: 1 }))
				.mockResolvedValueOnce(new Response("rate limited", { status: 429 }));

			await expect(provider.createSandbox(makeRequest())).rejects.toThrow(
				"session creation failed",
			);
		});

		it("caches environment and agent across calls", async () => {
			mockCreateSandboxFlow("session-1");

			await provider.createSandbox(makeRequest());
			expect(mockFetch).toHaveBeenCalledTimes(4);

			// Second call with same system prompt — only session + send
			mockFetch.mockClear();
			mockFetch
				.mockResolvedValueOnce(jsonResponse({ id: "session-2" }))
				.mockResolvedValueOnce(jsonResponse({}));

			const result = await provider.createSandbox(makeRequest());
			expect(result.instanceId).toBe("session-2");
			expect(mockFetch).toHaveBeenCalledTimes(2);
		});
	});

	describe("streamOutput", () => {
		it("maps agent events to StreamChunks", async () => {
			const events = [
				JSON.stringify({
					type: "agent.message",
					content: [{ type: "text", text: "Hello " }],
				}),
				JSON.stringify({
					type: "agent.tool_use",
					name: "bash",
				}),
				JSON.stringify({
					type: "agent.message",
					content: [{ type: "text", text: "Done." }],
				}),
				JSON.stringify({ type: "session.status_idle" }),
			];
			mockFetch.mockResolvedValueOnce(sseResponse(events));

			const chunks = await collect(provider.streamOutput("session-1"));

			expect(chunks).toEqual([
				{ type: "text", content: "Hello " },
				{
					type: "tool_use",
					content: "bash",
					metadata: { tool: "bash" },
				},
				{ type: "text", content: "Done." },
				{ type: "done", content: "" },
			]);
		});

		it("yields error on failed stream", async () => {
			mockFetch.mockResolvedValueOnce(
				new Response(null, {
					status: 500,
					statusText: "Server Error",
				}),
			);

			const chunks = await collect(provider.streamOutput("session-1"));

			expect(chunks).toHaveLength(1);
			expect(chunks[0].type).toBe("error");
			expect(chunks[0].content).toContain("Server Error");
		});

		it("yields done when stream ends without idle event", async () => {
			mockFetch.mockResolvedValueOnce(
				sseResponse([
					JSON.stringify({
						type: "agent.message",
						content: [{ type: "text", text: "Hi" }],
					}),
				]),
			);

			const chunks = await collect(provider.streamOutput("session-1"));

			expect(chunks).toHaveLength(2);
			expect(chunks[0]).toEqual({ type: "text", content: "Hi" });
			expect(chunks[1]).toEqual({ type: "done", content: "" });
		});

		it("skips unknown event types", async () => {
			mockFetch.mockResolvedValueOnce(
				sseResponse([
					JSON.stringify({ type: "session.status_running" }),
					JSON.stringify({
						type: "agent.message",
						content: [{ type: "text", text: "Hi" }],
					}),
					JSON.stringify({ type: "session.status_idle" }),
				]),
			);

			const chunks = await collect(provider.streamOutput("session-1"));

			expect(chunks).toEqual([
				{ type: "text", content: "Hi" },
				{ type: "done", content: "" },
			]);
		});
	});

	describe("sendMessage", () => {
		it("sends user message event to session", async () => {
			mockFetch.mockResolvedValueOnce(jsonResponse({}));

			await provider.sendMessage("session-1", "follow up question");

			expect(mockFetch).toHaveBeenCalledTimes(1);
			const [url, opts] = mockFetch.mock.calls[0];
			expect(url).toContain("/sessions/session-1/events");
			const body = JSON.parse(opts.body);
			expect(body.events[0]).toMatchObject({
				type: "user.message",
				content: [{ type: "text", text: "follow up question" }],
			});
		});

		it("throws on failure", async () => {
			mockFetch.mockResolvedValueOnce(
				new Response("not found", { status: 404 }),
			);

			await expect(provider.sendMessage("session-x", "hi")).rejects.toThrow(
				"send message failed",
			);
		});
	});

	describe("destroySandbox", () => {
		it("is a no-op", async () => {
			await provider.destroySandbox("session-1");
			expect(mockFetch).not.toHaveBeenCalled();
		});
	});
});
