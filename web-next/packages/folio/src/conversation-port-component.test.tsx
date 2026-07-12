import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, test } from "vitest";
import { FolioConversationController } from "./conversation-controller";
import type { FolioConversationSnapshot } from "./conversation-ports";
import { FakeConversationPort } from "./fake-conversation-port";
import { SessionView } from "./session-view";

describe("Folio port component integration", () => {
	test("renders a snapshot replayed through the deterministic fake host", async () => {
		const snapshot: FolioConversationSnapshot = {
			conversationId: "conversation-1",
			cursor: "cursor-0",
			view: {
				masthead: {
					repo: "example/repo",
					branch: null,
					title: "Port-driven session",
					agentName: "Agent",
					stateLabel: "ready",
				},
				messages: [],
				statusLine: { model: "model-1" },
			},
			queuedMessages: [],
			capabilities: {
				send: false,
				stop: false,
				retry: false,
				cancelQueuedMessage: false,
				decideApproval: false,
				decideReview: false,
				updateConversation: false,
			},
			artifacts: [],
			review: null,
			workspace: null,
			publication: null,
			failure: null,
		};
		const controller = new FolioConversationController(
			new FakeConversationPort(snapshot, [
				{
					cursor: "cursor-1",
					type: "message-upsert",
					message: {
						id: "message-1",
						role: "user",
						metadata: { author: "You" },
						parts: [{ type: "text", text: "Hello from the host port" }],
					},
				},
			]),
		);

		const result = await controller.follow();
		const html = renderToStaticMarkup(<SessionView session={result.view} />);

		expect(html).toContain("Port-driven session");
		expect(html).toContain("Hello from the host port");
		expect(html).toMatch(/^<div data-folio-root="surface">/);
	});
});
