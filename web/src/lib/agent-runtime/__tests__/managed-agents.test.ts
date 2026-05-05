import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { SandboxRequest } from "../types";

// Route the libsql client at a fresh temp file per test suite so cache
// inserts don't collide with dev data.
const tmpDir = mkdtempSync(join(tmpdir(), "managed-agents-test-"));
process.env.TURSO_DATABASE_URL = `file:${tmpDir}/test.db`;
process.env.ANTHROPIC_API_KEY = "sk-test";

// Mock the Anthropic SDK before importing the provider.
const createAgentMock = vi.fn();
const listAgentsMock = vi.fn();
const createEnvMock = vi.fn();
const createSessionMock = vi.fn();
const archiveSessionMock = vi.fn();
const deleteSessionMock = vi.fn();
const sendEventMock = vi.fn();
const streamEventsMock = vi.fn();
const listEventsMock = vi.fn();

vi.mock("@anthropic-ai/sdk", () => {
	class FakeAnthropic {
		beta = {
			agents: {
				create: createAgentMock,
				list: listAgentsMock,
			},
			environments: {
				create: createEnvMock,
			},
			sessions: {
				create: createSessionMock,
				archive: archiveSessionMock,
				delete: deleteSessionMock,
				events: {
					send: sendEventMock,
					stream: streamEventsMock,
					list: listEventsMock,
				},
			},
		};
	}
	return { default: FakeAnthropic };
});

async function loadProvider() {
	const { ManagedAgentsProvider } = await import("../managed-agents");
	const { __resetCacheForTests } = await import("../managed-agents-cache");
	__resetCacheForTests();
	return new ManagedAgentsProvider();
}

function baseRequest(overrides: Partial<SandboxRequest> = {}): SandboxRequest {
	return {
		sessionId: "sess_test_1",
		repo: "fairchild/workspaces",
		cloneUrl: "https://github.com/fairchild/workspaces.git",
		readOnly: true,
		systemPrompt: "You are a helpful coding agent.",
		message: "list the top-level files",
		tools: "conversational",
		envVars: { GITHUB_TOKEN: "ghp_test" },
		...overrides,
	};
}

beforeEach(() => {
	createAgentMock.mockReset();
	listAgentsMock.mockReset();
	createEnvMock.mockReset();
	createSessionMock.mockReset();
	archiveSessionMock.mockReset();
	deleteSessionMock.mockReset();
	sendEventMock.mockReset();
	streamEventsMock.mockReset();
	listEventsMock.mockReset();

	createAgentMock.mockResolvedValue({ id: "agent_01", version: 1 });
	createEnvMock.mockResolvedValue({ id: "env_01" });
	createSessionMock.mockResolvedValue({ id: "sesn_01" });
	sendEventMock.mockResolvedValue({});
	archiveSessionMock.mockResolvedValue({});
	deleteSessionMock.mockResolvedValue({});
	listAgentsMock.mockImplementation(() =>
		Promise.resolve({ data: [] } as { data: unknown[] }),
	);
});

afterEach(() => {
	Reflect.deleteProperty(process.env, "MANAGED_AGENTS_DESTROY_MODE");
});

process.on("exit", () => {
	try {
		rmSync(tmpDir, { recursive: true, force: true });
	} catch {}
});

describe("ManagedAgentsProvider.createSandbox", () => {
	it("caches the agent and environment between calls", async () => {
		const provider = await loadProvider();

		await provider.createSandbox(baseRequest());
		await provider.createSandbox(baseRequest({ sessionId: "sess_test_2" }));

		expect(createAgentMock).toHaveBeenCalledTimes(1);
		expect(createEnvMock).toHaveBeenCalledTimes(1);
		expect(createSessionMock).toHaveBeenCalledTimes(2);
	});

	it("does not mount a GitHub token for read-only sessions", async () => {
		const provider = await loadProvider();

		await provider.createSandbox(baseRequest());

		const call = createSessionMock.mock.calls[0][0];
		expect(call.agent).toBe("agent_01");
		expect(call.environment_id).toBe("env_01");
		expect(call.resources?.[0]).toMatchObject({
			type: "github_repository",
			url: "https://github.com/fairchild/workspaces",
			mount_path: "/workspace/repo",
		});
		expect(call.resources?.[0]).not.toHaveProperty("authorization_token");
	});

	it("mounts the provided GitHub token only for write-capable sessions", async () => {
		const provider = await loadProvider();

		await provider.createSandbox(baseRequest({ readOnly: false }));

		const call = createSessionMock.mock.calls[0][0];
		expect(call.resources?.[0]).toMatchObject({
			type: "github_repository",
			url: "https://github.com/fairchild/workspaces",
			mount_path: "/workspace/repo",
			authorization_token: "ghp_test",
		});
	});

	it("sends the initial user message after creating the session", async () => {
		const provider = await loadProvider();

		await provider.createSandbox(baseRequest());

		expect(sendEventMock).toHaveBeenCalledTimes(1);
		const [sessionId, params] = sendEventMock.mock.calls[0];
		expect(sessionId).toBe("sesn_01");
		expect(params.events[0]).toMatchObject({
			type: "user.message",
			content: [
				{
					type: "text",
					text: expect.stringContaining("list the top-level files"),
				},
			],
		});
	});

	it("returns the session id as the instanceId", async () => {
		const provider = await loadProvider();
		const result = await provider.createSandbox(baseRequest());
		expect(result).toEqual({ instanceId: "sesn_01", status: "ready" });
	});
});

describe("ManagedAgentsProvider.sendMessage", () => {
	it("sends exactly one user.message event to the session", async () => {
		const provider = await loadProvider();

		await provider.sendMessage("sesn_01", "follow-up question");

		expect(sendEventMock).toHaveBeenCalledTimes(1);
		const [sessionId, params] = sendEventMock.mock.calls[0];
		expect(sessionId).toBe("sesn_01");
		expect(params.events).toHaveLength(1);
		expect(params.events[0]).toEqual({
			type: "user.message",
			content: [{ type: "text", text: "follow-up question" }],
		});
	});
});

describe("ManagedAgentsProvider.streamOutput", () => {
	it("yields mapped chunks and terminates on end-of-turn", async () => {
		streamEventsMock.mockImplementation(async () => {
			return {
				async *[Symbol.asyncIterator]() {
					yield {
						id: "evt_a",
						type: "agent.message",
						processed_at: "t",
						content: [{ type: "text", text: "hi there" }],
					};
					yield {
						id: "evt_b",
						type: "agent.tool_use",
						processed_at: "t",
						name: "bash",
						input: { command: "ls" },
					};
					yield {
						id: "evt_c",
						type: "session.status_idle",
						processed_at: "t",
						stop_reason: { type: "end_turn" },
					};
				},
				controller: { abort: vi.fn() },
			};
		});

		const provider = await loadProvider();
		const chunks: unknown[] = [];
		for await (const chunk of provider.streamOutput("sesn_01")) {
			chunks.push(chunk);
		}

		expect(chunks).toEqual([
			{ type: "text", content: "hi there" },
			{
				type: "tool_use",
				content: "bash",
				metadata: { id: "evt_b", input: { command: "ls" } },
			},
			{ type: "done", content: "" },
		]);
	});
});

describe("ManagedAgentsProvider.destroySandbox", () => {
	it("archives the session by default", async () => {
		const provider = await loadProvider();
		await provider.destroySandbox("sesn_01");
		expect(archiveSessionMock).toHaveBeenCalledWith("sesn_01");
		expect(deleteSessionMock).not.toHaveBeenCalled();
	});

	it("deletes the session when MANAGED_AGENTS_DESTROY_MODE=delete", async () => {
		process.env.MANAGED_AGENTS_DESTROY_MODE = "delete";
		// Re-import so the provider picks up the env value at construction time.
		vi.resetModules();
		const { ManagedAgentsProvider } = await import("../managed-agents");
		const { __resetCacheForTests } = await import("../managed-agents-cache");
		__resetCacheForTests();
		const provider = new ManagedAgentsProvider();

		await provider.destroySandbox("sesn_01");
		expect(deleteSessionMock).toHaveBeenCalledWith("sesn_01");
		expect(archiveSessionMock).not.toHaveBeenCalled();
	});
});

describe("ManagedAgentsProvider.checkAvailability", () => {
	it("reports unavailable without an API key", async () => {
		const savedKey = process.env.ANTHROPIC_API_KEY;
		Reflect.deleteProperty(process.env, "ANTHROPIC_API_KEY");
		try {
			vi.resetModules();
			const { ManagedAgentsProvider } = await import("../managed-agents");
			const provider = new ManagedAgentsProvider();
			const result = await provider.checkAvailability();
			expect(result.available).toBe(false);
			expect(result.reason).toMatch(/ANTHROPIC_API_KEY/);
		} finally {
			if (savedKey) process.env.ANTHROPIC_API_KEY = savedKey;
		}
	});

	it("probes agents.list when a key is set", async () => {
		const provider = await loadProvider();
		const result = await provider.checkAvailability();
		expect(result.available).toBe(true);
		expect(listAgentsMock).toHaveBeenCalled();
	});
});
