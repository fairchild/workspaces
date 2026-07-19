/*
 * An anonymized durable host for the external-consumer compatibility fixture.
 * It intentionally imports only Folio's installed public conversation entry.
 */
import {
	FolioCapabilityUnavailableError,
	FolioUnknownCursorError,
	applyConversationEvent,
} from "@fairchild/folio/conversation";

const clone = (value) => structuredClone(value);

function initialSnapshot() {
	return {
		conversationId: "conversation-external-1",
		cursor: "external:0",
		view: {
			masthead: {
				repo: "example/private-host",
				branch: "conversation/external-1",
				title: "External consumer",
				agentName: "Host agent",
				stateLabel: "ready",
			},
			messages: [],
			statusLine: {
				model: "host-model",
				modelLabel: "Host model",
			},
			empty: {
				title: "Ready for a host-owned conversation.",
				hint: "Folio supplies the interface; this fixture owns the runtime.",
			},
		},
		queuedMessages: [
			{
				queueId: "queue-1",
				text: "A host-owned queued message",
				queuedAt: "2026-01-01T00:00:00.000Z",
				position: 1,
			},
		],
		capabilities: {
			send: true,
			stop: false,
			retry: true,
			cancelQueuedMessage: true,
			decideApproval: true,
			decideReview: true,
			updateConversation: true,
		},
		artifacts: [],
		review: null,
		workspace: {
			id: "workspace-external-1",
			label: "Host workspace",
			state: "needs-recovery",
			actions: ["recover"],
		},
		publication: {
			id: null,
			state: null,
			url: null,
			actions: ["publish"],
		},
		failure: null,
	};
}

export class AnonymizedDurableHost {
	#snapshot;
	#events;

	constructor(state) {
		this.#snapshot = clone(state?.snapshot ?? initialSnapshot());
		this.#events = clone(state?.events ?? []);
		this.calls = clone(state?.calls ?? []);
	}

	static createConversation() {
		return new AnonymizedDurableHost();
	}

	static createActiveConversation() {
		const host = new AnonymizedDurableHost();
		host.#append({
			type: "message-upsert",
			message: {
				id: "external-active-user",
				role: "user",
				metadata: { author: "You" },
				parts: [{ type: "text", text: "Stop this active turn safely." }],
			},
		});
		host.#append({
			type: "capabilities",
			capabilities: { ...host.#snapshot.capabilities, stop: true },
		});
		host.#append({
			type: "active-turn",
			activeTurn: {
				agentName: "Host agent",
				action: "Working",
				details: ["Awaiting a host stop command"],
			},
		});
		return host;
	}

	static restore(serialized) {
		return new AnonymizedDurableHost(JSON.parse(serialized));
	}

	serialize() {
		return JSON.stringify({
			snapshot: this.#snapshot,
			events: this.#events,
			calls: this.calls,
		});
	}

	readDurableSnapshot() {
		return clone(this.#snapshot);
	}

	recordFailure(message) {
		this.#append({ type: "failure", message });
		this.#append({ type: "complete" });
	}

	port({ disconnectAfterCursor } = {}) {
		// Port methods are deliberately detached from their object receiver; the
		// durable host remains the sole state and authority owner.
		// eslint-disable-next-line @typescript-eslint/no-this-alias
		const host = this;
		return {
			async readSnapshot(signal) {
				signal?.throwIfAborted();
				host.calls.push({ command: "readSnapshot" });
				return host.readDurableSnapshot();
			},

			async *readEvents(after, signal) {
				signal?.throwIfAborted();
				host.calls.push({ command: "readEvents", payload: after });
				const cursors = ["external:0", ...host.#events.map((event) => event.cursor)];
				const cursorIndex = cursors.indexOf(after);
				if (cursorIndex < 0) {
					throw new FolioUnknownCursorError(`unknown external cursor: ${after}`);
				}
				for (const event of host.#events.slice(cursorIndex)) {
					signal?.throwIfAborted();
					yield clone(event);
					if (event.cursor === disconnectAfterCursor) {
						throw new Error("anonymized transport disconnected");
					}
				}
			},

			async send(request, signal) {
				host.#require(
					request.retryOf
						? host.#snapshot.capabilities.retry
						: host.#snapshot.capabilities.send,
					request.retryOf ? "retry" : "send",
					signal,
				);
				host.calls.push({ command: "send", payload: clone(request) });
				const turn = host.#events.length + 1;
				host.#append({
					type: "message-upsert",
					message: {
						id: `external-user-${turn}`,
						role: "user",
						metadata: { author: "You" },
						parts: [{ type: "text", text: request.text }],
					},
				});
				host.#append({
					type: "capabilities",
					capabilities: { ...host.#snapshot.capabilities, stop: true },
				});
				host.#append({
					type: "active-turn",
					activeTurn: {
						agentName: "Host agent",
						action: "Working",
						details: ["Streaming through the host adapter"],
					},
				});
				host.#append({
					type: "message-upsert",
					message: {
						id: `external-assistant-${turn}`,
						role: "assistant",
						metadata: { author: "Host agent" },
						parts: [{ type: "text", text: "Completed by the external host." }],
					},
				});
				host.#append({
					type: "artifact",
					artifact: {
						id: `artifact-${turn}`,
						kind: "report",
						label: "Host-owned validation report",
					},
				});
				host.#append({
					type: "review",
					review: {
						id: `review-${turn}`,
						summary: "Ready for host review",
						changedFiles: ["docs/example.md"],
						state: "pending",
					},
				});
				host.#append({
					type: "capabilities",
					capabilities: { ...host.#snapshot.capabilities, stop: false },
				});
				host.#append({ type: "complete" });
				return host.#receipt();
			},

			async stop(signal) {
				host.#require(host.#snapshot.capabilities.stop, "stop", signal);
				host.calls.push({ command: "stop" });
				host.#append({ type: "failure", message: "Turn stopped by the host" });
				host.#append({
					type: "capabilities",
					capabilities: { ...host.#snapshot.capabilities, stop: false },
				});
				host.#append({ type: "complete" });
				return host.#receipt();
			},

			async cancelQueuedMessage(queueId, signal) {
				host.#require(
					host.#snapshot.capabilities.cancelQueuedMessage,
					"cancelQueuedMessage",
					signal,
				);
				host.calls.push({ command: "cancelQueuedMessage", payload: queueId });
				host.#append({
					type: "queued-messages",
					messages: host.#snapshot.queuedMessages.filter(
						(message) => message.queueId !== queueId,
					),
				});
				return host.#receipt();
			},

			async decideApproval(requestId, decision, signal) {
				host.#require(
					host.#snapshot.capabilities.decideApproval,
					"decideApproval",
					signal,
				);
				host.calls.push({
					command: "decideApproval",
					payload: { requestId, decision },
				});
				return host.#receipt();
			},

			async decideReview(decision, note, signal) {
				host.#require(
					host.#snapshot.capabilities.decideReview,
					"decideReview",
					signal,
				);
				host.calls.push({ command: "decideReview", payload: { decision, note } });
				if (host.#snapshot.review) {
					host.#append({
						type: "review",
						review: {
							...host.#snapshot.review,
							state: decision === "accept" ? "accepted" : "rejected",
						},
					});
				}
				return host.#receipt();
			},

			async updateConversation(update, signal) {
				host.#require(
					host.#snapshot.capabilities.updateConversation,
					"updateConversation",
					signal,
				);
				host.calls.push({ command: "updateConversation", payload: clone(update) });
				host.#append({ type: "conversation-updated", ...update });
				return host.#receipt();
			},

			async requestWorkspaceAction(action, signal) {
				host.#require(
					host.#snapshot.workspace?.actions.includes(action) === true,
					`workspace ${action}`,
					signal,
				);
				host.calls.push({ command: "requestWorkspaceAction", payload: action });
				host.#append({
					type: "workspace",
					workspace: {
						...host.#snapshot.workspace,
						state: "attached",
						actions: [],
					},
				});
				return host.#receipt();
			},

			async requestPublication(action, signal) {
				host.#require(
					host.#snapshot.publication?.actions.includes(action) === true,
					`publication ${action}`,
					signal,
				);
				host.calls.push({ command: "requestPublication", payload: action });
				host.#append({
					type: "publication",
					publication: {
						id: "publication-external-1",
						state: "open",
						url: null,
						actions: [],
					},
				});
				return host.#receipt();
			},
		};
	}

	#append(event) {
		const durableEvent = {
			...clone(event),
			cursor: `external:${this.#events.length + 1}`,
		};
		this.#events.push(durableEvent);
		this.#snapshot = applyConversationEvent(this.#snapshot, durableEvent);
		return durableEvent;
	}

	#receipt() {
		return { cursor: this.#snapshot.cursor };
	}

	#require(available, command, signal) {
		signal?.throwIfAborted();
		if (!available) {
			throw new FolioCapabilityUnavailableError(`${command} is unavailable`);
		}
	}
}
