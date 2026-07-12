/*
 * Workspaces' host adapter for Folio's public conversation port. Workspaces
 * keeps ownership of AI SDK streaming, authenticated routes, persistence,
 * sandboxes, and publication; this membrane projects their current state and
 * translates only explicitly granted Folio commands back into host callbacks.
 */
import {
	FolioCapabilityUnavailableError,
	FolioConversationController,
	type FolioCommandReceipt,
	type FolioConversationPort,
	type FolioConversationSnapshot,
	type FolioConversationUpdate,
	type FolioSendRequest,
} from "@fairchild/folio";
import type { ApprovalDecision } from "@/lib/agent-runtime/stream-chunk";

type HostCommand = void | Promise<void>;

export interface WorkspacesConversationHost {
	sendMessage: (request: FolioSendRequest) => HostCommand;
	cancelQueuedMessage: (queueId: string) => HostCommand;
	changeModel: (id: string) => HostCommand;
	changeTitle: (title: string) => HostCommand;
	stopTurn?: () => HostCommand;
	stopSandbox?: () => HostCommand;
	openPullRequest: (action: string) => HostCommand;
	answerApproval: (requestId: string, decision: ApprovalDecision) => Promise<void>;
}

function unavailable(command: string): never {
	throw new FolioCapabilityUnavailableError(
		`Workspaces does not currently grant the Folio ${command} capability`,
	);
}

function commandReceipt(snapshot: FolioConversationSnapshot): FolioCommandReceipt {
	return { cursor: snapshot.cursor };
}

function assertNotAborted(signal?: AbortSignal): void {
	signal?.throwIfAborted();
}

/**
 * Adapts the host-owned live snapshot and command implementations to Folio's
 * public port. `readEvents` is intentionally empty: Workspaces' existing
 * `useChat` runtime supplies newer projected snapshots on React renders, while
 * Folio's controller remains the command/capability authority for each one.
 */
export function createWorkspacesConversationPort(
	snapshot: FolioConversationSnapshot,
	host: WorkspacesConversationHost,
): FolioConversationPort {
	const receipt = () => commandReceipt(snapshot);
	return {
		async readSnapshot(signal) {
			assertNotAborted(signal);
			return snapshot;
		},
		async *readEvents(after, signal) {
			assertNotAborted(signal);
			if (after !== snapshot.cursor) {
				throw new Error(`unknown Workspaces conversation cursor: ${after}`);
			}
		},
		async send(request, signal) {
			assertNotAborted(signal);
			const granted = request.retryOf
				? snapshot.capabilities.retry
				: snapshot.capabilities.send;
			if (!granted) unavailable(request.retryOf ? "retry" : "send");
			await host.sendMessage(request);
			assertNotAborted(signal);
			return receipt();
		},
		async stop(signal) {
			assertNotAborted(signal);
			if (!snapshot.capabilities.stop || !host.stopTurn) unavailable("stop");
			await host.stopTurn();
			assertNotAborted(signal);
			return receipt();
		},
		async cancelQueuedMessage(queueId, signal) {
			assertNotAborted(signal);
			if (!snapshot.capabilities.cancelQueuedMessage) {
				unavailable("queued-message cancellation");
			}
			await host.cancelQueuedMessage(queueId);
			assertNotAborted(signal);
			return receipt();
		},
		async decideApproval(requestId, decision, signal) {
			assertNotAborted(signal);
			if (!snapshot.capabilities.decideApproval) unavailable("approval decision");
			await host.answerApproval(requestId, decision);
			assertNotAborted(signal);
			return receipt();
		},
		async decideReview() {
			return unavailable("review decision");
		},
		async updateConversation(update: FolioConversationUpdate, signal) {
			assertNotAborted(signal);
			if (!snapshot.capabilities.updateConversation) {
				unavailable("conversation update");
			}
			if (update.model !== undefined) await host.changeModel(update.model);
			if (update.title !== undefined) await host.changeTitle(update.title);
			assertNotAborted(signal);
			return receipt();
		},
		async requestWorkspaceAction(action, signal) {
			assertNotAborted(signal);
			if (!snapshot.workspace?.actions.includes(action) || !host.stopSandbox) {
				unavailable(`workspace ${action}`);
			}
			if (action !== "stop") unavailable(`workspace ${action}`);
			await host.stopSandbox();
			assertNotAborted(signal);
			return receipt();
		},
		async requestPublication(action, signal) {
			assertNotAborted(signal);
			if (!snapshot.publication?.actions.includes(action)) {
				unavailable(`publication ${action}`);
			}
			await host.openPullRequest(action);
			assertNotAborted(signal);
			return receipt();
		},
	};
}

/** A fully public-API Folio controller seeded from Workspaces' live projection. */
export function createWorkspacesFolioConversation(
	snapshot: FolioConversationSnapshot,
	host: WorkspacesConversationHost,
): FolioConversationController {
	const port = createWorkspacesConversationPort(snapshot, host);
	return FolioConversationController.fromSnapshot(port, snapshot);
}
