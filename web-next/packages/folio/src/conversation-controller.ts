/* Pure replay state machine over the host-neutral Folio conversation port. */
import type {
	FolioCommandReceipt,
	FolioConversationActions,
	FolioConversationEvent,
	FolioConversationPort,
	FolioConversationSnapshot,
	FolioConversationUpdate,
	FolioSendRequest,
} from "./conversation-ports";
import type { ApprovalDecision } from "./types";

function upsertById<T extends { id: string }>(items: readonly T[], item: T): T[] {
	const index = items.findIndex((candidate) => candidate.id === item.id);
	if (index < 0) return [...items, item];
	return items.map((candidate, candidateIndex) =>
		candidateIndex === index ? item : candidate,
	);
}

export function applyConversationEvent(
	snapshot: FolioConversationSnapshot,
	event: FolioConversationEvent,
): FolioConversationSnapshot {
	const next = { ...snapshot, cursor: event.cursor };
	switch (event.type) {
		case "message-upsert":
			return {
				...next,
				view: {
					...snapshot.view,
					messages: upsertById(snapshot.view.messages, event.message),
				},
			};
		case "active-turn":
			return {
				...next,
				failure: event.activeTurn ? null : snapshot.failure,
				view: {
					...snapshot.view,
					activeTurn: event.activeTurn ?? undefined,
				},
			};
		case "queued-messages":
			return { ...next, queuedMessages: event.messages };
		case "conversation-updated":
			return {
				...next,
				view: {
					...snapshot.view,
					masthead: {
						...snapshot.view.masthead,
						title: event.title ?? snapshot.view.masthead.title,
					},
					statusLine: {
						...snapshot.view.statusLine,
						model: event.model ?? snapshot.view.statusLine.model,
						modelLabel: event.modelLabel ?? snapshot.view.statusLine.modelLabel,
					},
				},
			};
		case "capabilities":
			return { ...next, capabilities: event.capabilities };
		case "status":
			return { ...next, view: { ...snapshot.view, statusLine: event.status } };
		case "artifact":
			return { ...next, artifacts: upsertById(snapshot.artifacts, event.artifact) };
		case "review":
			return { ...next, review: event.review };
		case "workspace":
			return { ...next, workspace: event.workspace };
		case "publication":
			return { ...next, publication: event.publication };
		case "failure":
			return {
				...next,
				failure: event.message,
				view: {
					...snapshot.view,
					activeTurn: undefined,
				},
			};
		case "complete":
			return {
				...next,
				view: { ...snapshot.view, activeTurn: undefined },
			};
	}
}

export class FolioConversationController {
	#snapshot: FolioConversationSnapshot | null = null;
	#following = false;

	constructor(readonly port: FolioConversationPort) {}

	/**
	 * Starts from a snapshot the host already projected. This is the bridge for
	 * hosts whose established runtime owns live state (for example an SDK hook):
	 * they can use the same port-backed command membrane without an async blank
	 * render while `readSnapshot()` repeats data they already have.
	 */
	static fromSnapshot(
		port: FolioConversationPort,
		snapshot: FolioConversationSnapshot,
	): FolioConversationController {
		const controller = new FolioConversationController(port);
		controller.#snapshot = snapshot;
		return controller;
	}

	get snapshot(): FolioConversationSnapshot | null {
		return this.#snapshot;
	}

	async hydrate(signal?: AbortSignal): Promise<FolioConversationSnapshot> {
		this.#snapshot = await this.port.readSnapshot(signal);
		return this.#snapshot;
	}

	async follow(
		onChange?: (snapshot: FolioConversationSnapshot) => void,
		signal?: AbortSignal,
	): Promise<FolioConversationSnapshot> {
		if (this.#following) throw new FolioFollowInProgressError();
		this.#following = true;
		try {
			let current = this.#snapshot ?? (await this.hydrate(signal));
			for await (const event of this.port.readEvents(current.cursor, signal)) {
				current = applyConversationEvent(current, event);
				this.#snapshot = current;
				onChange?.(current);
			}
			return current;
		} finally {
			this.#following = false;
		}
	}

	send(request: FolioSendRequest, signal?: AbortSignal): Promise<FolioCommandReceipt> {
		return this.port.send(request, signal);
	}

	stop(signal?: AbortSignal): Promise<FolioCommandReceipt> {
		return this.port.stop(signal);
	}

	cancelQueuedMessage(queueId: string, signal?: AbortSignal): Promise<FolioCommandReceipt> {
		return this.port.cancelQueuedMessage(queueId, signal);
	}

	decideApproval(
		requestId: string,
		decision: ApprovalDecision,
		signal?: AbortSignal,
	): Promise<FolioCommandReceipt> {
		return this.port.decideApproval(requestId, decision, signal);
	}

	decideReview(
		decision: "accept" | "reject",
		note?: string,
		signal?: AbortSignal,
	): Promise<FolioCommandReceipt> {
		return this.port.decideReview(decision, note, signal);
	}

	updateConversation(
		update: FolioConversationUpdate,
		signal?: AbortSignal,
	): Promise<FolioCommandReceipt> {
		return this.port.updateConversation(update, signal);
	}

	requestWorkspaceAction(
		action: string,
		signal?: AbortSignal,
	): Promise<FolioCommandReceipt> {
		return this.port.requestWorkspaceAction(action, signal);
	}

	requestPublication(
		action: string,
		signal?: AbortSignal,
	): Promise<FolioCommandReceipt> {
		return this.port.requestPublication(action, signal);
	}
}

export class FolioFollowInProgressError extends Error {
	constructor() {
		super("conversation follow is already in progress");
	}
}

export function createPortBackedConversationActions(
	controller: FolioConversationController,
	requestId: () => string,
	onCommandError: (error: unknown) => void,
): FolioConversationActions {
	const snapshot = controller.snapshot;
	if (!snapshot) throw new Error("conversation controller must hydrate before creating actions");
	const { capabilities, workspace, publication } = snapshot;
	const publicationAction = publication?.actions[0];
	const run = (command: Promise<FolioCommandReceipt>): void => {
		void command.catch(onCommandError);
	};
	return {
		send: capabilities.send
			? (text) => run(controller.send({ text, requestId: requestId() }))
			: undefined,
		retry: capabilities.retry
			? (messageId, text) =>
					run(controller.send({ text, requestId: requestId(), retryOf: messageId }))
			: undefined,
		cancelQueuedMessage: capabilities.cancelQueuedMessage
			? (queueId) => run(controller.cancelQueuedMessage(queueId))
			: undefined,
		changeModel: capabilities.updateConversation
			? (model) => run(controller.updateConversation({ model }))
			: undefined,
		changeTitle: capabilities.updateConversation
			? (title) => run(controller.updateConversation({ title }))
			: undefined,
		stopTurn: capabilities.stop ? () => run(controller.stop()) : undefined,
		stopWorkspace: workspace?.actions.includes("stop")
			? () => run(controller.requestWorkspaceAction("stop"))
			: undefined,
		requestPublication: publicationAction
			? (action = publicationAction) => run(controller.requestPublication(action))
			: undefined,
		decideApproval: capabilities.decideApproval
			? async (requestId, decision) => {
					await controller.decideApproval(requestId, decision);
				}
			: undefined,
	};
}
