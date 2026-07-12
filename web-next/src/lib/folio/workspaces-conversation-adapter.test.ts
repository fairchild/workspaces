import type { FolioConversationSnapshot } from "@fairchild/folio";
import { describe, expect, test, vi } from "vitest";
import {
	createWorkspacesConversationPort,
	createWorkspacesFolioConversation,
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

		await controller.send({ text: "hello", idempotencyKey: "send-1" });
		await controller.send({
			text: "again",
			idempotencyKey: "send-2",
			retryOf: "message-1",
		});
		await controller.cancelQueuedMessage("queue-1");
		await controller.updateConversation({ model: "model-2", title: "Title" });
		await controller.stop();
		await controller.requestWorkspaceAction("stop");
		await controller.requestPublication("open");
		await controller.decideApproval("approval-1", "allow");

		expect(callbacks.sendMessage).toHaveBeenNthCalledWith(1, {
			text: "hello",
			idempotencyKey: "send-1",
		});
		expect(callbacks.sendMessage).toHaveBeenNthCalledWith(2, {
			text: "again",
			idempotencyKey: "send-2",
			retryOf: "message-1",
		});
		expect(callbacks.cancelQueuedMessage).toHaveBeenCalledWith("queue-1");
		expect(callbacks.changeModel).toHaveBeenCalledWith("model-2");
		expect(callbacks.changeTitle).toHaveBeenCalledWith("Title");
		expect(callbacks.stopTurn).toHaveBeenCalledOnce();
		expect(callbacks.stopSandbox).toHaveBeenCalledOnce();
		expect(callbacks.openPullRequest).toHaveBeenCalledWith("open");
		expect(callbacks.answerApproval).toHaveBeenCalledWith("approval-1", "allow");
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
		await expect(unknown.next()).rejects.toThrow("unknown Workspaces conversation cursor");
	});
});
