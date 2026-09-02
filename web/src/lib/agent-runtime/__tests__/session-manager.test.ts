import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
	ComputeProvider,
	ComputeProviderDescriptor,
	SandboxResult,
	SnapshotCapable,
	StreamChunk,
} from "../types";

// --- vi.mock() declarations (hoisted) ---

vi.mock("../../agent-sessions");
vi.mock("../../chat");
vi.mock("../../github");
vi.mock("../persona-loader");
vi.mock("../provider-registry");

// --- Import mocked functions AFTER mock declarations ---

import {
	claimSnapshotSession,
	createSession,
	getActiveSessionForThread,
	getSession,
	getSnapshotSessionForThread,
	updateComputeInstance,
	updateSessionStatus,
	updateSnapshotId,
} from "../../agent-sessions";
import { getChatMessages, pushChatMessage } from "../../chat";
import { addDiscussionComment } from "../../github";
import {
	buildConversationalPrompt,
	fetchRepoMemory,
	resolvePersona,
} from "../persona-loader";
import { getRegistry } from "../provider-registry";

// --- Import real ComputeProviderRegistry for wrapping the mock provider ---

const { ComputeProviderRegistry } = await vi.importActual<
	typeof import("../provider-registry")
>("../provider-registry");

// --- Import the class under test (not the singleton) ---

import { SessionManager } from "../session-manager";

// --- Helpers ---

const DESCRIPTOR: ComputeProviderDescriptor = {
	id: "vercel-sandbox",
	displayName: "Vercel Sandbox",
	maxSessionDuration: 3600,
	supportsSnapshot: true,
	supportsStreaming: true,
	terminalMode: "pty",
};

function makeMockProvider(): ComputeProvider &
	SnapshotCapable & {
		checkAvailability: ReturnType<typeof vi.fn>;
		createSandbox: ReturnType<typeof vi.fn>;
		streamOutput: ReturnType<typeof vi.fn>;
		sendMessage: ReturnType<typeof vi.fn>;
		destroySandbox: ReturnType<typeof vi.fn>;
		createSnapshot: ReturnType<typeof vi.fn>;
		restoreSnapshot: ReturnType<typeof vi.fn>;
	} {
	return {
		descriptor: DESCRIPTOR,
		checkAvailability: vi.fn().mockResolvedValue({ available: true }),
		createSandbox: vi
			.fn()
			.mockResolvedValue({ instanceId: "inst-1", status: "ready" }),
		streamOutput: vi.fn().mockImplementation(async function* () {
			yield { type: "text", content: "Hello" } satisfies StreamChunk;
			yield { type: "done", content: "" } satisfies StreamChunk;
		}),
		sendMessage: vi.fn().mockResolvedValue(undefined),
		destroySandbox: vi.fn().mockResolvedValue(undefined),
		createSnapshot: vi.fn().mockResolvedValue("snap-new"),
		restoreSnapshot: vi
			.fn()
			.mockResolvedValue({ instanceId: "inst-restored", status: "ready" }),
	};
}

const PERSONA = {
	name: "april-clearwater",
	displayName: "April Clearwater",
	role: "Application Lead",
	personaPath: ".agents/skills/april/references/april-clearwater.md",
	systemPrompt: "# April Clearwater\n\nYou are April.",
};

let threadCounter = 0;

function makeParams(overrides: Record<string, unknown> = {}) {
	threadCounter += 1;
	return {
		repo: "acme/app",
		agentName: "april-clearwater",
		message: "hello",
		userId: "user-1",
		githubToken: "ghp_test",
		threadId: `thread-${threadCounter}`,
		...overrides,
	};
}

/** Collect all chunks from the async generator. */
async function collect(
	gen: AsyncGenerator<StreamChunk>,
): Promise<StreamChunk[]> {
	const chunks: StreamChunk[] = [];
	for await (const c of gen) {
		chunks.push(c);
	}
	return chunks;
}

// --- Tests ---

describe("SessionManager", () => {
	let manager: SessionManager;
	let provider: ReturnType<typeof makeMockProvider>;

	beforeEach(() => {
		vi.clearAllMocks();
		threadCounter = 0;

		manager = new SessionManager();
		provider = makeMockProvider();

		// Default mock returns
		vi.mocked(resolvePersona).mockResolvedValue(PERSONA);
		vi.mocked(buildConversationalPrompt).mockReturnValue("system prompt");
		vi.mocked(getActiveSessionForThread).mockResolvedValue(null);
		vi.mocked(getSnapshotSessionForThread).mockResolvedValue(null);
		vi.mocked(createSession).mockResolvedValue(undefined);
		vi.mocked(updateSessionStatus).mockResolvedValue(undefined);
		vi.mocked(updateComputeInstance).mockResolvedValue(undefined);
		vi.mocked(updateSnapshotId).mockResolvedValue(undefined);
		vi.mocked(pushChatMessage).mockResolvedValue(undefined);
		vi.mocked(addDiscussionComment).mockResolvedValue({
			id: "dc-1",
			url: "https://example.com",
		});
		vi.mocked(getChatMessages).mockResolvedValue([]);
		vi.mocked(getSession).mockResolvedValue(null);
		vi.mocked(claimSnapshotSession).mockResolvedValue(true);

		// Wire registry mock to wrap the mock provider in the real registry class
		const registry = new ComputeProviderRegistry([provider]);
		vi.mocked(getRegistry).mockResolvedValue(registry);
	});

	// 1. Fresh session happy path
	it("creates sandbox, streams, snapshots, and persists on fresh session", async () => {
		const chunks = await collect(manager.handleMention(makeParams()));

		expect(provider.createSandbox).toHaveBeenCalledTimes(1);
		expect(provider.streamOutput).toHaveBeenCalledTimes(1);
		expect(provider.createSnapshot).toHaveBeenCalledTimes(1);
		expect(vi.mocked(pushChatMessage)).toHaveBeenCalledTimes(1);
		expect(vi.mocked(pushChatMessage).mock.calls[0][0].content).toBe("Hello");

		const textChunks = chunks.filter((c) => c.type === "text");
		expect(textChunks).toHaveLength(1);
		expect(textChunks[0].content).toBe("Hello");
	});

	// 1b. Repo memory reaches the sandbox's system prompt.
	// Without this the persona pointer names rules the session never receives.
	it("carries fetched repo memory into the sandbox system prompt", async () => {
		vi.mocked(fetchRepoMemory).mockResolvedValue(
			"## Writing Voice\n\n- Marker.",
		);
		vi.mocked(buildConversationalPrompt).mockImplementation(
			(persona, repoMemory) =>
				`${persona.systemPrompt}\n---\n${repoMemory ?? ""}`,
		);

		const params = makeParams();
		await collect(manager.handleMention(params));

		expect(fetchRepoMemory).toHaveBeenCalledWith(
			params.githubToken,
			"acme",
			"app",
		);
		expect(provider.createSandbox).toHaveBeenCalledTimes(1);
		const { systemPrompt } = provider.createSandbox.mock.calls[0][0];
		expect(systemPrompt).toContain("- Marker.");
	});

	// 2. Snapshot restore happy path
	it("restores from snapshot when a snapshotted session exists", async () => {
		const params = makeParams();
		vi.mocked(getSnapshotSessionForThread).mockResolvedValue({
			id: "session-snap",
			userId: "user-1",
			repo: "acme/app",
			agentName: "april-clearwater",
			computeBackend: "vercel-sandbox",
			computeInstanceId: "old-inst",
			snapshotId: "snap-1",
			claudeSessionId: "claude-sess-1",
			threadId: params.threadId as string,
			discussionId: null,
			status: "snapshotted",
			createdAt: new Date().toISOString(),
			lastActivityAt: new Date().toISOString(),
		});

		const chunks = await collect(manager.handleMention(params));

		expect(provider.restoreSnapshot).toHaveBeenCalledWith("snap-1");
		expect(provider.sendMessage).toHaveBeenCalledWith(
			"inst-restored",
			expect.any(String),
			expect.objectContaining({ claudeSessionId: "claude-sess-1" }),
		);
		expect(provider.createSnapshot).toHaveBeenCalledTimes(1);

		const textChunks = chunks.filter((c) => c.type === "text");
		expect(textChunks).toHaveLength(1);
	});

	// 3. Active session resume
	it("resumes an active session by sending a message", async () => {
		const params = makeParams();
		vi.mocked(getActiveSessionForThread).mockResolvedValue({
			id: "session-active",
			userId: "user-1",
			repo: "acme/app",
			agentName: "april-clearwater",
			computeBackend: "vercel-sandbox",
			computeInstanceId: "live-inst",
			snapshotId: null,
			claudeSessionId: "claude-sess-2",
			threadId: params.threadId as string,
			discussionId: null,
			status: "active",
			createdAt: new Date().toISOString(),
			lastActivityAt: new Date().toISOString(),
		});

		const chunks = await collect(manager.handleMention(params));

		expect(provider.sendMessage).toHaveBeenCalledWith("live-inst", "hello", {
			claudeSessionId: "claude-sess-2",
		});
		expect(provider.streamOutput).toHaveBeenCalledWith("live-inst");
		expect(provider.createSnapshot).toHaveBeenCalledTimes(1);

		const textChunks = chunks.filter((c) => c.type === "text");
		expect(textChunks).toHaveLength(1);
	});

	// 4. Stale active session falls through to fresh
	it("falls through to fresh session when active sandbox is stale", async () => {
		const params = makeParams();
		vi.mocked(getActiveSessionForThread).mockResolvedValue({
			id: "session-stale",
			userId: "user-1",
			repo: "acme/app",
			agentName: "april-clearwater",
			computeBackend: "vercel-sandbox",
			computeInstanceId: "dead-inst",
			snapshotId: null,
			claudeSessionId: null,
			threadId: params.threadId as string,
			discussionId: null,
			status: "active",
			createdAt: new Date().toISOString(),
			lastActivityAt: new Date().toISOString(),
		});

		// sendMessage rejects → sandbox is gone
		provider.sendMessage.mockRejectedValueOnce(new Error("sandbox not found"));

		const chunks = await collect(manager.handleMention(params));

		// Stale session marked completed
		expect(vi.mocked(updateSessionStatus)).toHaveBeenCalledWith(
			"session-stale",
			"completed",
		);
		// Falls through to fresh session
		expect(provider.createSandbox).toHaveBeenCalledTimes(1);

		const textChunks = chunks.filter((c) => c.type === "text");
		expect(textChunks).toHaveLength(1);
	});

	// 5. Snapshot claim race — loser gets fresh session
	it("creates fresh session when snapshot claim race is lost", async () => {
		const params = makeParams();
		vi.mocked(getSnapshotSessionForThread).mockResolvedValue({
			id: "session-race",
			userId: "user-1",
			repo: "acme/app",
			agentName: "april-clearwater",
			computeBackend: "vercel-sandbox",
			computeInstanceId: "old-inst",
			snapshotId: "snap-race",
			claudeSessionId: null,
			threadId: params.threadId as string,
			discussionId: null,
			status: "snapshotted",
			createdAt: new Date().toISOString(),
			lastActivityAt: new Date().toISOString(),
		});
		vi.mocked(claimSnapshotSession).mockResolvedValue(false);

		const chunks = await collect(manager.handleMention(params));

		expect(provider.restoreSnapshot).not.toHaveBeenCalled();
		expect(provider.createSandbox).toHaveBeenCalledTimes(1);

		const textChunks = chunks.filter((c) => c.type === "text");
		expect(textChunks).toHaveLength(1);
	});

	// 6. Snapshot restore failure falls through to fresh
	it("falls through to fresh session when snapshot restore fails", async () => {
		const params = makeParams();
		vi.mocked(getSnapshotSessionForThread).mockResolvedValue({
			id: "session-restore-fail",
			userId: "user-1",
			repo: "acme/app",
			agentName: "april-clearwater",
			computeBackend: "vercel-sandbox",
			computeInstanceId: "old-inst",
			snapshotId: "snap-bad",
			claudeSessionId: null,
			threadId: params.threadId as string,
			discussionId: null,
			status: "snapshotted",
			createdAt: new Date().toISOString(),
			lastActivityAt: new Date().toISOString(),
		});

		provider.restoreSnapshot.mockRejectedValueOnce(
			new Error("snapshot corrupted"),
		);

		const chunks = await collect(manager.handleMention(params));

		expect(vi.mocked(updateSessionStatus)).toHaveBeenCalledWith(
			"session-restore-fail",
			"completed",
		);
		expect(provider.createSandbox).toHaveBeenCalledTimes(1);

		const textChunks = chunks.filter((c) => c.type === "text");
		expect(textChunks).toHaveLength(1);
	});

	// 7. Empty response — pushChatMessage NOT called
	it("does not persist when agent produces no text", async () => {
		provider.streamOutput.mockImplementation(async function* () {
			yield { type: "done", content: "" } satisfies StreamChunk;
		});

		await collect(manager.handleMention(makeParams()));

		expect(vi.mocked(pushChatMessage)).not.toHaveBeenCalled();
	});

	// 8. Snapshot creation failure — status stays "active"
	it('leaves session "active" when snapshot creation fails', async () => {
		provider.createSnapshot.mockRejectedValueOnce(
			new Error("snapshot quota exceeded"),
		);

		await collect(manager.handleMention(makeParams()));

		// snapshotAndRelease falls back to "active" status
		expect(vi.mocked(updateSessionStatus)).toHaveBeenCalledWith(
			expect.any(String),
			"active",
		);
		// Should NOT have called updateSnapshotId
		expect(vi.mocked(updateSnapshotId)).not.toHaveBeenCalled();
	});

	// 9. Invalid repo format
	it("yields error for invalid repo format", async () => {
		const chunks = await collect(
			manager.handleMention(makeParams({ repo: "no-slash" })),
		);

		expect(chunks).toHaveLength(1);
		expect(chunks[0].type).toBe("error");
		expect(chunks[0].content).toContain("Invalid repo");
	});

	// 10. Unknown agent
	it("yields error when persona is not found", async () => {
		vi.mocked(resolvePersona).mockResolvedValue(null);

		const chunks = await collect(manager.handleMention(makeParams()));

		expect(chunks).toHaveLength(1);
		expect(chunks[0].type).toBe("error");
		expect(chunks[0].content).toContain("not found");
	});

	// 11. Provider unavailable
	it("yields error when compute provider is unavailable", async () => {
		provider.checkAvailability.mockResolvedValue({
			available: false,
			reason: "API key missing",
		});

		const chunks = await collect(manager.handleMention(makeParams()));

		expect(chunks).toHaveLength(1);
		expect(chunks[0].type).toBe("error");
		expect(chunks[0].content).toContain("unavailable");
	});
});
