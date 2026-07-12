import { describe, expect, test, vi } from "vitest";
import {
	FolioConversationController,
	FolioFollowInProgressError,
	createPortBackedConversationActions,
} from "./conversation-controller";
import type {
	FolioConversationEvent,
	FolioConversationSnapshot,
} from "./conversation-ports";
import { FolioCapabilityUnavailableError } from "./conversation-ports";
import { FakeConversationPort } from "./fake-conversation-port";

function snapshot(cursor = "cursor-0"): FolioConversationSnapshot {
	return {
		conversationId: "conversation-1",
		cursor,
		view: {
			masthead: {
				repo: "example/repo",
				branch: null,
				title: "Example",
				agentName: "Agent",
				stateLabel: "",
			},
			messages: [],
			statusLine: { model: "model-1" },
		},
		queuedMessages: [],
		capabilities: {
			send: true,
			stop: true,
			retry: true,
			cancelQueuedMessage: true,
			decideApproval: true,
			decideReview: true,
			updateConversation: true,
		},
		artifacts: [],
		review: null,
		workspace: { id: "workspace-1", state: "attached", actions: ["recover"] },
		publication: { id: null, state: null, url: null, actions: ["publish"] },
		failure: null,
	};
}

const userMessage = {
	id: "message-1",
	role: "user" as const,
	metadata: { author: "You" },
	parts: [{ type: "text" as const, text: "Hello" }],
};

const events: FolioConversationEvent[] = [
	{ cursor: "cursor-1", type: "message-upsert", message: userMessage },
	{
		cursor: "cursor-2",
		type: "active-turn",
		activeTurn: { agentName: "Agent", action: "Working", details: [] },
	},
	{
		cursor: "cursor-3",
		type: "artifact",
		artifact: { id: "artifact-1", kind: "diff", label: "Change" },
	},
	{
		cursor: "cursor-4",
		type: "review",
		review: {
			id: "review-1",
			summary: "Ready",
			changedFiles: ["example.txt"],
			state: "pending",
		},
	},
	{
		cursor: "cursor-5",
		type: "workspace",
		workspace: { id: "workspace-1", state: "attached", actions: [] },
	},
	{
		cursor: "cursor-6",
		type: "publication",
		publication: { id: "pr-1", state: "open", url: "https://example.test/1", actions: [] },
	},
	{ cursor: "cursor-7", type: "complete" },
];

class BlockingConversationPort extends FakeConversationPort {
	readonly started: Promise<void>;
	#markStarted!: () => void;
	#release!: () => void;
	readonly released: Promise<void>;

	constructor(initial: FolioConversationSnapshot) {
		super(initial);
		this.started = new Promise((resolve) => {
			this.#markStarted = resolve;
		});
		this.released = new Promise((resolve) => {
			this.#release = resolve;
		});
	}

	release(): void {
		this.#release();
	}

	override async *readEvents(
		after: string,
		signal?: AbortSignal,
	): AsyncIterable<FolioConversationEvent> {
		this.#markStarted();
		await this.released;
		yield* super.readEvents(after, signal);
	}
}

describe("FolioConversationController", () => {
	test("replays ordered host events into host-neutral view state", async () => {
		const controller = new FolioConversationController(
			new FakeConversationPort(snapshot(), events),
		);

		const result = await controller.follow();

		expect(result.cursor).toBe("cursor-7");
		expect(result.view.messages).toEqual([userMessage]);
		expect(result.view.activeTurn).toBeUndefined();
		expect(result.artifacts).toHaveLength(1);
		expect(result.review?.summary).toBe("Ready");
		expect(result.workspace?.state).toBe("attached");
		expect(result.publication?.state).toBe("open");
	});

	test("preserves the durable cursor across disconnect and resumes without duplicates", async () => {
		const disconnected = new FolioConversationController(
			new FakeConversationPort(snapshot(), events, "cursor-2"),
		);
		await expect(disconnected.follow()).rejects.toThrow("deterministic disconnect");
		expect(disconnected.snapshot?.cursor).toBe("cursor-2");

		const resumedSnapshot = {
			...disconnected.snapshot!,
			cursor: "cursor-2",
		};
		const resumed = new FolioConversationController(
			new FakeConversationPort(resumedSnapshot, events),
		);
		const result = await resumed.follow();

		expect(result.cursor).toBe("cursor-7");
		expect(result.view.messages).toHaveLength(1);
	});

	test("rejects a concurrent follower instead of interleaving snapshots", async () => {
		const port = new BlockingConversationPort(snapshot());
		const controller = new FolioConversationController(port);
		const first = controller.follow();
		await port.started;

		await expect(controller.follow()).rejects.toBeInstanceOf(FolioFollowInProgressError);
		port.release();
		await first;
	});

	test("rejects unknown resume cursors instead of replaying duplicates", async () => {
		const port = new FakeConversationPort(snapshot(), events);
		const iterator = port.readEvents("unknown-cursor")[Symbol.asyncIterator]();
		await expect(iterator.next()).rejects.toThrow("unknown conversation cursor");
	});

	test("projects a stopped turn as terminal failure state", async () => {
		const controller = new FolioConversationController(
			new FakeConversationPort(snapshot(), [
				events[1],
				{ cursor: "cursor-3", type: "failure", message: "Turn stopped" },
				{ cursor: "cursor-4", type: "complete" },
			]),
		);

		const result = await controller.follow();
		expect(result.failure).toBe("Turn stopped");
		expect(result.view.activeTurn).toBeUndefined();
	});

	test("clears a prior failure when a retry becomes active", async () => {
		const failed = snapshot("cursor-3");
		failed.failure = "Turn stopped";
		const controller = new FolioConversationController(
			new FakeConversationPort(failed, [
				{
					cursor: "cursor-4",
					type: "active-turn",
					activeTurn: { agentName: "Agent", action: "Retrying", details: [] },
				},
				{ cursor: "cursor-5", type: "complete" },
			]),
		);

		const result = await controller.follow();
		expect(result.failure).toBeNull();
		expect(result.view.activeTurn).toBeUndefined();
	});

	test("capability events become the fake host's command authority", async () => {
		const nextCapabilities = { ...snapshot().capabilities, stop: false };
		const port = new FakeConversationPort(snapshot(), [
			{ cursor: "cursor-1", type: "capabilities", capabilities: nextCapabilities },
		]);
		const controller = new FolioConversationController(port);
		await controller.follow();

		await expect(controller.stop()).rejects.toBeInstanceOf(
			FolioCapabilityUnavailableError,
		);
	});

	test("derives a total UI action membrane from a hydrated port", async () => {
		const port = new FakeConversationPort(snapshot());
		const controller = new FolioConversationController(port);
		await controller.hydrate();
		let key = 0;
		const actions = createPortBackedConversationActions(
			controller,
			() => `request-${++key}`,
			vi.fn(),
		);

		actions.send?.("Hello");
		actions.retry?.("message-1", "Again");
		actions.cancelQueuedMessage?.("queue-1");
		actions.changeTitle?.("Updated");
		actions.requestPublication?.();

		expect(port.calls.filter((call) => call.command !== "readSnapshot")).toEqual([
			{
				command: "send",
				payload: { text: "Hello", idempotencyKey: "request-1" },
			},
			{
				command: "send",
				payload: { text: "Again", idempotencyKey: "request-2", retryOf: "message-1" },
			},
			{ command: "cancelQueuedMessage", payload: "queue-1" },
			{ command: "updateConversation", payload: { title: "Updated" } },
			{ command: "requestPublication", payload: "publish" },
		]);
	});

	test("derives actions from a host-projected snapshot without reading it twice", () => {
		const projected = snapshot("cursor-projected");
		const port = new FakeConversationPort(projected);
		const controller = FolioConversationController.fromSnapshot(port, projected);
		const actions = createPortBackedConversationActions(
			controller,
			() => "request-1",
			vi.fn(),
		);

		actions.send?.("Hello");

		expect(controller.snapshot).toBe(projected);
		expect(port.calls).toEqual([
			{
				command: "send",
				payload: { text: "Hello", idempotencyKey: "request-1" },
			},
		]);
	});

	test("routes a command rejected after an authority change to the host error channel", async () => {
		const port = new FakeConversationPort(snapshot(), [
			{
				cursor: "cursor-1",
				type: "capabilities",
				capabilities: { ...snapshot().capabilities, stop: false },
			},
		]);
		const controller = new FolioConversationController(port);
		await controller.hydrate();
		const onCommandError = vi.fn();
		const actions = createPortBackedConversationActions(
			controller,
			() => "request-1",
			onCommandError,
		);
		await controller.follow();

		actions.stopTurn?.();

		await vi.waitFor(() =>
			expect(onCommandError).toHaveBeenCalledWith(
				expect.any(FolioCapabilityUnavailableError),
			),
		);
	});

	test("fake host denies commands that durable capabilities do not grant", async () => {
		const denied = snapshot();
		denied.capabilities = {
			...denied.capabilities,
			stop: false,
		};
		denied.workspace = { id: "workspace-1", state: "failed", actions: [] };
		const port = new FakeConversationPort(denied);

		await expect(port.stop()).rejects.toBeInstanceOf(FolioCapabilityUnavailableError);
		await expect(port.requestWorkspaceAction("recover")).rejects.toBeInstanceOf(
			FolioCapabilityUnavailableError,
		);
	});

	test("fake host records idempotent send and authority requests", async () => {
		const port = new FakeConversationPort(snapshot());
		const controller = new FolioConversationController(port);
		const sendReceipt = await controller.send({ text: "Hello", idempotencyKey: "request-1" });
		await controller.decideApproval("approval-1", "allow");
		await controller.decideReview("accept", "ship it");
		await controller.updateConversation({ title: "Updated" });
		await controller.requestWorkspaceAction("recover");
		await controller.requestPublication("publish");

		expect(sendReceipt.cursor).toBe("cursor-0");

		expect(port.calls.map((call) => call.command)).toEqual([
			"send",
			"decideApproval",
			"decideReview",
			"updateConversation",
			"requestWorkspaceAction",
			"requestPublication",
		]);
	});
});
