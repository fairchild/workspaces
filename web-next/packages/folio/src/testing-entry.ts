/** Deterministic test host for consumers of the Folio port contract. */
export {
	FakeConversationPort,
} from "./fake-conversation-port";
export {
	FolioCapabilityUnavailableError,
	FolioUnknownCursorError,
} from "./conversation.js";
export type { FakeConversationCall } from "./fake-conversation-port";
