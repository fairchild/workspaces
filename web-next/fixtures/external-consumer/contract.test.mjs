/* End-to-end compatibility checks run against the installed Folio tarball. */
import assert from "node:assert/strict";
import test from "node:test";
import {
	FolioConversationController,
	FolioUnknownCursorError,
} from "@fairchild/folio/conversation";
import { AnonymizedDurableHost } from "./host-adapter.mjs";

const conversationId = "conversation-external-1";
const cursor = (ordinal, id = conversationId) => `${id}:generation-1:${ordinal}`;

function assertStopAuthorityInvariant(snapshots) {
	for (const snapshot of snapshots) {
		assert.equal(
			snapshot.capabilities.stop && snapshot.view.activeTurn === undefined,
			false,
			`stop authority requires an active turn at ${snapshot.cursor}`,
		);
	}
}

test("creates, streams, disconnects, resumes, and reloads durable host state", async () => {
	const host = AnonymizedDurableHost.createConversation();
	const disconnected = new FolioConversationController(
		host.port({ disconnectAfterCursor: cursor(3) }),
	);
	const created = await disconnected.hydrate();
	assert.equal(created.conversationId, conversationId);
	assert.equal(created.view.messages.length, 0);

	const receipt = await disconnected.send({
		text: "Prove the external boundary.",
		requestId: "request-external-1",
	});
	assert.equal(receipt.cursor, cursor(8));
	const transitions = [];
	const observedCursors = [];
	await assert.rejects(
		disconnected.follow((snapshot) => {
			transitions.push(snapshot);
			observedCursors.push(snapshot.cursor);
		}),
		/transport disconnected/,
	);
	assert.equal(disconnected.snapshot?.cursor, cursor(3));

	const resumed = FolioConversationController.fromSnapshot(
		host.port(),
		disconnected.snapshot,
	);
	const completed = await resumed.follow((snapshot) => {
		transitions.push(snapshot);
		observedCursors.push(snapshot.cursor);
	});
	assert.equal(completed.cursor, cursor(8));
	assert.deepEqual(
		observedCursors,
		Array.from({ length: 8 }, (_, index) => cursor(index + 1)),
	);
	assert.equal(new Set(observedCursors).size, observedCursors.length);
	assertStopAuthorityInvariant(transitions);
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
	await controller.decideApproval("approval-external-1", "allow");
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
			"decideApproval",
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
	const stopTransitions = [];
	await stoppedController.follow((snapshot) => stopTransitions.push(snapshot));
	assertStopAuthorityInvariant(stopTransitions);
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
	const host = AnonymizedDurableHost.createConversation(conversationId);
	const foreignHost = AnonymizedDurableHost.createConversation("conversation-external-2");
	await host.port().send({ text: "Local history", requestId: "request-local" });
	const foreignReceipt = await foreignHost.port().send({
		text: "Foreign history",
		requestId: "request-foreign",
	});
	assert.equal(foreignReceipt.cursor, cursor(8, "conversation-external-2"));
	const iterator = host.port().readEvents(foreignReceipt.cursor)[Symbol.asyncIterator]();
	await assert.rejects(iterator.next(), FolioUnknownCursorError);

	const tampered = JSON.parse(host.serialize());
	tampered.events[0].cursor = cursor(1, "conversation-external-2");
	assert.throws(
		() => AnonymizedDurableHost.restore(JSON.stringify(tampered)),
		/event cursor .* does not match/,
	);

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
