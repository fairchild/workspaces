import { describe, expect, test, vi } from "vitest";
import { createWorkspacesFolioActions } from "./workspaces-conversation-adapter";

describe("createWorkspacesFolioActions", () => {
	test("translates Workspaces callbacks into explicit Folio capabilities", async () => {
		const callbacks = {
			sendMessage: vi.fn(),
			cancelQueuedMessage: vi.fn(),
			changeModel: vi.fn(),
			changeTitle: vi.fn(),
			stopTurn: vi.fn(),
			stopSandbox: vi.fn(),
			openPullRequest: vi.fn(),
			answerApproval: vi.fn(async () => undefined),
		};
		const actions = createWorkspacesFolioActions(callbacks);

		actions.send?.("hello");
		actions.retry?.("message-1", "again");
		actions.cancelQueuedMessage?.("queue-1");
		actions.changeModel?.("model-2");
		actions.changeTitle?.("Title");
		actions.stopTurn?.();
		actions.stopWorkspace?.();
		actions.requestPublication?.();
		await actions.decideApproval?.("approval-1", "allow");

		expect(callbacks.sendMessage).toHaveBeenNthCalledWith(1, "hello");
		expect(callbacks.sendMessage).toHaveBeenNthCalledWith(2, "again");
		expect(callbacks.cancelQueuedMessage).toHaveBeenCalledWith("queue-1");
		expect(callbacks.changeModel).toHaveBeenCalledWith("model-2");
		expect(callbacks.changeTitle).toHaveBeenCalledWith("Title");
		expect(callbacks.stopTurn).toHaveBeenCalledOnce();
		expect(callbacks.stopSandbox).toHaveBeenCalledOnce();
		expect(callbacks.openPullRequest).toHaveBeenCalledOnce();
		expect(callbacks.answerApproval).toHaveBeenCalledWith("approval-1", "allow");
	});

	test("does not invent unavailable optional authority", () => {
		const actions = createWorkspacesFolioActions({
			sendMessage: vi.fn(),
			cancelQueuedMessage: vi.fn(),
			changeModel: vi.fn(),
			changeTitle: vi.fn(),
			openPullRequest: vi.fn(),
			answerApproval: vi.fn(async () => undefined),
		});

		expect(actions.stopTurn).toBeUndefined();
		expect(actions.stopWorkspace).toBeUndefined();
	});
});
