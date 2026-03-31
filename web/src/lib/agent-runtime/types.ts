import type { ComputeBackendId } from "../types";

/** Static metadata about a compute provider's capabilities. */
export interface ComputeProviderDescriptor {
	id: ComputeBackendId;
	displayName: string;
	maxSessionDuration: number;
	supportsSnapshot: boolean;
	supportsStreaming: boolean;
}

export interface ComputeProviderAvailability {
	available: boolean;
	reason?: string;
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
	sendMessage(instanceId: string, message: string): Promise<void>;

	/** Stop and clean up a sandbox. */
	destroySandbox(instanceId: string): Promise<void>;
}

/** Optional capability: snapshot and restore sandbox state. */
export interface SnapshotCapable {
	createSnapshot(instanceId: string): Promise<string>;
	restoreSnapshot(snapshotId: string): Promise<SandboxResult>;
}
