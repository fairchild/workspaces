import {
	FolioUnknownCursorError,
	type FolioConversationSnapshot,
	type FolioConversationUpdate,
} from "@fairchild/folio";
import { describe, expect, test, vi } from "vitest";
import {
	createWorkspacesChatRequestBody,
	createWorkspacesConversationPort,
	createWorkspacesFolioConversation,
	createWorkspacesProjectionCursor,
	type WorkspacesConversationHost,
} from "./workspaces-conversation-adapter";

function snapshot(): FolioConversationSnapshot {
	return {
		conversationId: "session-1",
		cursor: "workspaces:7",
		view: {
			masthead: {
				repo: "fairchild/workspaces",
				branch: "main",
				title: "Adapter proof",
				agentName: "Claude",
				stateLabel: "sandbox live",
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
			decideReview: false,
			updateConversation: true,
		},
		artifacts: [],
		review: null,
		workspace: { id: "session-1", state: "live", actions: ["stop"] },
		publication: { id: null, state: null, url: null, actions: ["open"] },
		failure: null,
	};
}

function host(): WorkspacesConversationHost {
	return {
		sendMessage: vi.fn(),
		cancelQueuedMessage: vi.fn(),
		changeModel: vi.fn(),
		changeTitle: vi.fn(),
		stopTurn: vi.fn(),
		stopSandbox: vi.fn(),
		openPullRequest: vi.fn(),
		answerApproval: vi.fn(async () => undefined),
	};
}

describe("Workspaces Folio conversation adapter", () => {
	test("translates every granted Folio command into host authority", async () => {
		const callbacks = host();
		const controller = createWorkspacesFolioConversation(snapshot(), callbacks);

		const sendReceipt = await controller.send({ text: "hello", requestId: "send-1" });
		const retryReceipt = await controller.send({
			text: "again",
			requestId: "send-2",
			retryOf: "message-1",
		});
		await controller.cancelQueuedMessage("queue-1");
		await controller.updateConversation({ model: "model-2" });
		await controller.updateConversation({ title: "Title" });
		await controller.stop();
		await controller.requestWorkspaceAction("stop");
		await controller.requestPublication("open");
		await controller.decideApproval("approval-1", "allow");

		expect(callbacks.sendMessage).toHaveBeenNthCalledWith(1, {
			text: "hello",
			requestId: "send-1",
		});
		expect(callbacks.sendMessage).toHaveBeenNthCalledWith(2, {
			text: "again",
			requestId: "send-2",
			retryOf: "message-1",
		});
		expect(sendReceipt.cursor).toBeNull();
		expect(retryReceipt.cursor).toBeNull();
		expect(callbacks.cancelQueuedMessage).toHaveBeenCalledWith("queue-1");
		expect(callbacks.changeModel).toHaveBeenCalledWith("model-2");
		expect(callbacks.changeTitle).toHaveBeenCalledWith("Title");
		expect(callbacks.stopTurn).toHaveBeenCalledOnce();
		expect(callbacks.stopSandbox).toHaveBeenCalledOnce();
		expect(callbacks.openPullRequest).toHaveBeenCalledWith("open");
		expect(callbacks.answerApproval).toHaveBeenCalledWith("approval-1", "allow");
	});

	test("rejects a combined mutable update instead of partially applying it", async () => {
		const callbacks = host();
		const controller = createWorkspacesFolioConversation(snapshot(), callbacks);
		const invalid = {
			model: "model-2",
			title: "Title",
		} as unknown as FolioConversationUpdate;

		await expect(controller.updateConversation(invalid)).rejects.toThrow(
			"exactly one field",
		);
		await expect(
			controller.updateConversation({} as unknown as FolioConversationUpdate),
		).rejects.toThrow("exactly one field");
		expect(callbacks.changeModel).not.toHaveBeenCalled();
		expect(callbacks.changeTitle).not.toHaveBeenCalled();
	});

	test("fails closed when the projected snapshot withholds authority", async () => {
		const denied = snapshot();
		denied.capabilities = {
			...denied.capabilities,
			stop: false,
			decideApproval: false,
		};
		denied.workspace = { ...denied.workspace!, actions: [] };
		denied.publication = { ...denied.publication!, actions: [] };
		const controller = createWorkspacesFolioConversation(denied, host());

		await expect(controller.stop()).rejects.toThrow("stop capability");
		await expect(controller.requestWorkspaceAction("stop")).rejects.toThrow(
			"workspace stop capability",
		);
		await expect(controller.requestPublication("open")).rejects.toThrow(
			"publication open capability",
		);
		await expect(controller.decideApproval("approval-1", "deny")).rejects.toThrow(
			"approval decision capability",
		);
	});

	test("exposes only the current host projection through the snapshot stream", async () => {
		const projected = snapshot();
		const port = createWorkspacesConversationPort(projected, host());

		await expect(port.readSnapshot()).resolves.toBe(projected);
		const current = port.readEvents(projected.cursor)[Symbol.asyncIterator]();
		await expect(current.next()).resolves.toEqual({ done: true, value: undefined });
		const unknown = port.readEvents("stale")[Symbol.asyncIterator]();
		await expect(unknown.next()).rejects.toBeInstanceOf(FolioUnknownCursorError);
	});

	test("fingerprints every material projection change, including same-message streaming", () => {
		const initial = snapshot();
		const { conversationId } = initial;
		const projection: Omit<
			FolioConversationSnapshot,
			"conversationId" | "cursor"
		> = {
			view: initial.view,
			queuedMessages: initial.queuedMessages,
			capabilities: initial.capabilities,
			artifacts: initial.artifacts,
			review: initial.review,
			workspace: initial.workspace,
			publication: initial.publication,
			failure: initial.failure,
		};
		const baseline = createWorkspacesProjectionCursor(conversationId, projection);
		const changes: Array<Omit<FolioConversationSnapshot, "conversationId" | "cursor">> = [
			{
				...projection,
				view: {
					...projection.view,
					messages: [
						{ id: "message-1", role: "assistant", parts: [{ type: "text", text: "A" }] },
					],
				},
			},
			{
				...projection,
				view: {
					...projection.view,
					masthead: { ...projection.view.masthead, title: "Changed" },
				},
			},
			{
				...projection,
				view: {
					...projection.view,
					statusLine: { ...projection.view.statusLine, model: "model-2" },
				},
			},
			{ ...projection, workspace: { ...projection.workspace!, state: "parked" } },
		];

		const cursors = changes.map((change) =>
			createWorkspacesProjectionCursor(conversationId, change),
		);
		expect(new Set([baseline, ...cursors])).toHaveLength(cursors.length + 1);
	});

	test("preserves public send correlation and retry provenance in Workspaces HTTP bodies", () => {
		const request = { text: "Again", requestId: "request-2", retryOf: "message-1" };

		expect(createWorkspacesChatRequestBody(request)).toEqual(request);
		expect(createWorkspacesChatRequestBody(request, true)).toEqual({
			...request,
			queue: true,
		});
	});

	test("does not report failure when cancellation races after host acceptance", async () => {
		let accept!: () => void;
		const accepted = new Promise<void>((resolve) => {
			accept = resolve;
		});
		const callbacks = host();
		callbacks.sendMessage = vi.fn(() => accepted);
		const port = createWorkspacesConversationPort(snapshot(), callbacks);
		const abort = new AbortController();

		const command = port.send(
			{ text: "Hello", requestId: "request-1" },
			abort.signal,
		);
		abort.abort();
		accept();

		await expect(command).resolves.toEqual({ cursor: null });
	});
});
