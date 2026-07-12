/* Deterministic host adapter for Folio contract and state-machine tests. */
import type {
	FolioCommandReceipt,
	FolioConversationEvent,
	FolioConversationPort,
	FolioConversationSnapshot,
	FolioConversationUpdate,
	FolioSendRequest,
} from "./conversation-ports";
import {
	FolioCapabilityUnavailableError,
	FolioUnknownCursorError,
} from "./conversation-ports";

export interface FakeConversationCall {
	command: string;
	payload?: unknown;
}

export class FakeConversationPort implements FolioConversationPort {
	readonly calls: FakeConversationCall[] = [];
	#capabilities: FolioConversationSnapshot["capabilities"];
	#workspace: FolioConversationSnapshot["workspace"];
	#publication: FolioConversationSnapshot["publication"];
	#cursor: FolioConversationSnapshot["cursor"];

	constructor(
		readonly initialSnapshot: FolioConversationSnapshot,
		readonly events: readonly FolioConversationEvent[] = [],
		readonly disconnectAfterCursor?: string,
	) {
		const cursors = events.map((event) => event.cursor);
		if (new Set(cursors).size !== cursors.length) {
			throw new Error("fake conversation cursors must be unique");
		}
		this.#capabilities = initialSnapshot.capabilities;
		this.#workspace = initialSnapshot.workspace;
		this.#publication = initialSnapshot.publication;
		this.#cursor = initialSnapshot.cursor;
	}

	async readSnapshot(signal?: AbortSignal): Promise<FolioConversationSnapshot> {
		signal?.throwIfAborted();
		this.calls.push({ command: "readSnapshot" });
		return this.initialSnapshot;
	}

	async *readEvents(
		after: string,
		signal?: AbortSignal,
	): AsyncIterable<FolioConversationEvent> {
		this.calls.push({ command: "readEvents", payload: after });
		const eventIndex = this.events.findIndex((event) => event.cursor === after);
		if (eventIndex < 0 && after !== this.initialSnapshot.cursor) {
			throw new FolioUnknownCursorError(`unknown conversation cursor: ${after}`);
		}
		const startIndex = eventIndex < 0 ? 0 : eventIndex + 1;
		for (const event of this.events.slice(startIndex)) {
			signal?.throwIfAborted();
			this.#cursor = event.cursor;
			if (event.type === "capabilities") this.#capabilities = event.capabilities;
			if (event.type === "workspace") this.#workspace = event.workspace;
			if (event.type === "publication") this.#publication = event.publication;
			yield event;
			if (event.cursor === this.disconnectAfterCursor) {
				throw new Error("deterministic disconnect");
			}
		}
	}

	async send(request: FolioSendRequest): Promise<FolioCommandReceipt> {
		this.#require(
			request.retryOf ? this.#capabilities.retry : this.#capabilities.send,
			request.retryOf ? "retry" : "send",
		);
		this.calls.push({ command: "send", payload: request });
		return this.#receipt();
	}

	async stop(): Promise<FolioCommandReceipt> {
		this.#require(this.#capabilities.stop, "stop");
		this.calls.push({ command: "stop" });
		return this.#receipt();
	}

	async cancelQueuedMessage(queueId: string): Promise<FolioCommandReceipt> {
		this.#require(
			this.#capabilities.cancelQueuedMessage,
			"cancelQueuedMessage",
		);
		this.calls.push({ command: "cancelQueuedMessage", payload: queueId });
		return this.#receipt();
	}

	async decideApproval(
		requestId: string,
		decision: "allow" | "deny",
	): Promise<FolioCommandReceipt> {
		this.#require(this.#capabilities.decideApproval, "decideApproval");
		this.calls.push({ command: "decideApproval", payload: { requestId, decision } });
		return this.#receipt();
	}

	async decideReview(decision: "accept" | "reject", note?: string): Promise<FolioCommandReceipt> {
		this.#require(this.#capabilities.decideReview, "decideReview");
		this.calls.push({ command: "decideReview", payload: { decision, note } });
		return this.#receipt();
	}

	async updateConversation(update: FolioConversationUpdate): Promise<FolioCommandReceipt> {
		this.#require(this.#capabilities.updateConversation, "updateConversation");
		this.calls.push({ command: "updateConversation", payload: update });
		return this.#receipt();
	}

	async requestWorkspaceAction(action: string): Promise<FolioCommandReceipt> {
		this.#require(
			this.#workspace?.actions.includes(action) === true,
			"requestWorkspaceAction",
		);
		this.calls.push({ command: "requestWorkspaceAction", payload: action });
		return this.#receipt();
	}

	async requestPublication(action: string): Promise<FolioCommandReceipt> {
		this.#require(
			this.#publication?.actions.includes(action) === true,
			"requestPublication",
		);
		this.calls.push({ command: "requestPublication", payload: action });
		return this.#receipt();
	}

	#receipt(): FolioCommandReceipt {
		return { cursor: this.#cursor };
	}

	#require(available: boolean, command: string): void {
		if (!available) throw new FolioCapabilityUnavailableError(`${command} is unavailable`);
	}
}
