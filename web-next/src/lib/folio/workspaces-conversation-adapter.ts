/*
 * Workspaces-to-Folio action adapter. It translates host vocabulary into
 * Folio's public capability object without granting the package route, Git,
 * sandbox, persistence, authentication, or publication implementations.
 */
import type { FolioConversationActions } from "@fairchild/folio";
import type { ApprovalDecision } from "@/lib/agent-runtime/stream-chunk";

export interface WorkspacesConversationCallbacks {
	sendMessage: (text: string) => void;
	cancelQueuedMessage: (queueId: string) => void;
	changeModel: (id: string) => void;
	changeTitle: (title: string) => void;
	stopTurn?: () => void;
	stopSandbox?: () => void;
	openPullRequest: () => void;
	answerApproval: (requestId: string, decision: ApprovalDecision) => Promise<void>;
}

export function createWorkspacesFolioActions(
	callbacks: WorkspacesConversationCallbacks,
): FolioConversationActions {
	return {
		send: callbacks.sendMessage,
		retry: (_messageId, text) => callbacks.sendMessage(text),
		cancelQueuedMessage: callbacks.cancelQueuedMessage,
		changeModel: callbacks.changeModel,
		changeTitle: callbacks.changeTitle,
		stopTurn: callbacks.stopTurn,
		stopWorkspace: callbacks.stopSandbox,
		requestPublication: callbacks.openPullRequest,
		decideApproval: callbacks.answerApproval,
	};
}
