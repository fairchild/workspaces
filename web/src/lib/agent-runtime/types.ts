import type { ComputeBackendId } from "../types";

/** Static metadata about a compute provider's capabilities. */
export interface ComputeProviderDescriptor {
	id: ComputeBackendId;
	displayName: string;
	maxSessionDuration: number;
	supportsSnapshot: boolean;
	supportsStreaming: boolean;
	/**
	 * How the provider exposes its terminal surface. "pty" = interactive
	 * ttyd/WebSocket (Vercel, etc.). "transcript" = read-only view
	 * of tool-call events (managed-agents, where bash is turn-based).
	 * Defaults to "pty" when omitted.
	 */
	terminalMode?: "pty" | "transcript";
}

export interface ComputeProviderAvailability {
	available: boolean;
	reason?: string;
}

/** A recent chat message passed as context to the agent. */
export interface ContextMessage {
	author: string;
	authorType: "user" | "agent" | "bot";
	content: string;
	timestamp: string;
}

/** Request to create a compute sandbox for an agent session. */
export interface SandboxRequest {
	sessionId: string;
	repo: string;
	cloneUrl: string;
	branch?: string;
	readOnly: boolean;
	systemPrompt: string;
	message: string;
	tools: "conversational" | "full";
	envVars?: Record<string, string>;
	/** Recent messages for inline context (prepended to the user message). */
	contextMessages?: ContextMessage[];
	/** Pre-formatted full chat history for a searchable file in the sandbox. */
	chatHistory?: string;
	/** Claude Code session ID for --session-id flag (enables --resume on follow-ups). */
	claudeSessionId?: string;
}

/** Result from creating a compute sandbox. */
export interface SandboxResult {
	instanceId: string;
	status: "ready" | "provisioning";
}

/** A chunk of output from the agent running inside a sandbox. */
export interface StreamChunk {
	type: "text" | "tool_use" | "tool_result" | "status" | "error" | "done";
	content: string;
	metadata?: Record<string, unknown>;
}

/**
 * Core compute provider interface.
 * Mirrors Swift WorkspaceProviderProtocol — each backend implements this
 * to provide sandboxed environments for agent sessions.
 */
export interface ComputeProvider {
	readonly descriptor: ComputeProviderDescriptor;

	/** Check if this provider is available and configured. */
	checkAvailability(): Promise<ComputeProviderAvailability>;

	/** Create a sandbox, clone the repo, and start an agent session. */
	createSandbox(request: SandboxRequest): Promise<SandboxResult>;

	/** Stream output from an active sandbox session. */
	streamOutput(instanceId: string): AsyncGenerator<StreamChunk>;

	/** Send a follow-up message to an existing sandbox session. */
	sendMessage(
		instanceId: string,
		message: string,
		context?: { chatHistory?: string; claudeSessionId?: string },
	): Promise<void>;

	/** Stop and clean up a sandbox. */
	destroySandbox(instanceId: string): Promise<void>;
}

/** Optional capability: snapshot and restore sandbox state. */
export interface SnapshotCapable {
	createSnapshot(instanceId: string): Promise<string>;
	restoreSnapshot(snapshotId: string): Promise<SandboxResult>;
}

/** Type guard for providers that support snapshot/restore. */
export function isSnapshotCapable(
	provider: ComputeProvider,
): provider is ComputeProvider & SnapshotCapable {
	return provider.descriptor.supportsSnapshot;
}

/** Liveness + terminal URL for a compute sandbox. */
export type SandboxState =
	| { alive: false }
	| { alive: true; terminalUrl?: string };

/** Optional capability: terminal access to a running sandbox. */
export interface TerminalCapable {
	createTerminalSandbox(params: {
		cloneUrl: string;
		branch?: string;
	}): Promise<SandboxResult>;
	resolveSandboxState(instanceId: string): Promise<SandboxState>;
}

/** Type guard for providers that support interactive terminal access. */
export function isTerminalCapable(
	provider: ComputeProvider,
): provider is ComputeProvider & TerminalCapable {
	const mode = provider.descriptor.terminalMode;
	return mode === "pty" || mode === undefined;
}
