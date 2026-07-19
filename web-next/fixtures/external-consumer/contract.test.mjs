/* End-to-end compatibility checks run against the installed Folio tarball. */
import assert from "node:assert/strict";
import test from "node:test";
import {
	FolioConversationController,
	FolioUnknownCursorError,
} from "@fairchild/folio/conversation";
import { AnonymizedDurableHost } from "./host-adapter.mjs";

test("creates, streams, disconnects, resumes, and reloads durable host state", async () => {
	const host = AnonymizedDurableHost.createConversation();
	const disconnected = new FolioConversationController(
		host.port({ disconnectAfterCursor: "external:3" }),
	);
	const created = await disconnected.hydrate();
	assert.equal(created.conversationId, "conversation-external-1");
	assert.equal(created.view.messages.length, 0);

	const receipt = await disconnected.send({
		text: "Prove the external boundary.",
		requestId: "request-external-1",
	});
	assert.equal(receipt.cursor, "external:8");
	await assert.rejects(disconnected.follow(), /transport disconnected/);
	assert.equal(disconnected.snapshot?.cursor, "external:3");

	const resumed = FolioConversationController.fromSnapshot(
		host.port(),
		disconnected.snapshot,
	);
	const completed = await resumed.follow();
	assert.equal(completed.cursor, "external:8");
	assert.deepEqual(
		completed.view.messages.map((message) => message.role),
		["user", "assistant"],
	);
	assert.equal(completed.artifacts[0].label, "Host-owned validation report");
	assert.equal(completed.review?.state, "pending");
	assert.equal(completed.view.activeTurn, undefined);

	const reloadedHost = AnonymizedDurableHost.restore(host.serialize());
	const reloaded = await new FolioConversationController(reloadedHost.port()).hydrate();
	assert.equal(reloaded.cursor, completed.cursor);
	assert.deepEqual(reloaded.view.messages, completed.view.messages);
	assert.deepEqual(reloaded.artifacts, completed.artifacts);
});

test("keeps stop, failure, review, workspace, and publication authority in the host", async () => {
	const host = AnonymizedDurableHost.createConversation();
	const controller = new FolioConversationController(host.port());
	await controller.hydrate();

	await controller.cancelQueuedMessage("queue-1");
	await controller.updateConversation({ title: "Host-renamed conversation" });
	await controller.requestWorkspaceAction("recover");
	await controller.send({ text: "Prepare evidence.", requestId: "request-external-2" });
	await controller.decideReview("accept", "Ship it");
	await controller.requestPublication("publish");

	const projected = await new FolioConversationController(host.port()).hydrate();
	assert.equal(projected.queuedMessages.length, 0);
	assert.equal(projected.view.masthead.title, "Host-renamed conversation");
	assert.equal(projected.workspace?.state, "attached");
	assert.equal(projected.review?.state, "accepted");
	assert.equal(projected.publication?.state, "open");
	assert.equal(projected.failure, null);
	assert.deepEqual(
		host.calls
			.filter((call) => !["readSnapshot", "readEvents"].includes(call.command))
			.map((call) => call.command),
		[
			"cancelQueuedMessage",
			"updateConversation",
			"requestWorkspaceAction",
			"send",
			"decideReview",
			"requestPublication",
		],
	);

	const stoppedHost = AnonymizedDurableHost.createActiveConversation();
	const stoppedController = new FolioConversationController(stoppedHost.port());
	const active = await stoppedController.hydrate();
	assert.equal(active.capabilities.stop, true);
	assert.notEqual(active.view.activeTurn, undefined);
	await stoppedController.stop();
	const stopped = await new FolioConversationController(stoppedHost.port()).hydrate();
	assert.equal(stopped.failure, "Turn stopped by the host");
	assert.equal(stopped.capabilities.stop, false);
	assert.equal(stopped.view.activeTurn, undefined);

	const failedHost = AnonymizedDurableHost.createConversation();
	failedHost.recordFailure("Host execution failed safely");
	const failed = await new FolioConversationController(failedHost.port()).hydrate();
	assert.equal(failed.failure, "Host execution failed safely");
});

test("rejects foreign cursors and aborted commands without guessing", async () => {
	const host = AnonymizedDurableHost.createConversation();
	const iterator = host.port().readEvents("foreign:9")[Symbol.asyncIterator]();
	await assert.rejects(iterator.next(), FolioUnknownCursorError);

	const abort = new AbortController();
	abort.abort();
	await assert.rejects(
		host.port().send(
			{ text: "Do not send", requestId: "request-aborted" },
			abort.signal,
		),
		(error) => error?.name === "AbortError",
	);
});
