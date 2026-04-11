import type {
	ComputeProvider,
	ComputeProviderAvailability,
	ComputeProviderDescriptor,
	SandboxRequest,
	SandboxResult,
	StreamChunk,
} from "./types";

/**
 * GitHub Actions provider — stub.
 * Will bridge web chat dispatch to workflow_dispatch events on self-hosted runners.
 */
export class GitHubActionsProvider implements ComputeProvider {
	readonly descriptor: ComputeProviderDescriptor = {
		id: "github-actions",
		displayName: "GitHub Actions",
		maxSessionDuration: 6 * 60 * 60 * 1000, // 6 hours
		supportsSnapshot: false,
		supportsStreaming: false,
		supportsTerminal: false,
	};

	async checkAvailability(): Promise<ComputeProviderAvailability> {
		return {
			available: false,
			reason: "GitHub Actions provider not yet implemented",
		};
	}

	async createSandbox(_request: SandboxRequest): Promise<SandboxResult> {
		throw new Error("GitHub Actions provider not yet implemented");
	}

	async *streamOutput(_instanceId: string): AsyncGenerator<StreamChunk> {
		yield {
			type: "error",
			content: "GitHub Actions provider not yet implemented",
		};
	}

	async sendMessage(_instanceId: string, _message: string): Promise<void> {
		throw new Error("GitHub Actions provider not yet implemented");
	}

	async destroySandbox(_instanceId: string): Promise<void> {
		throw new Error("GitHub Actions provider not yet implemented");
	}
}
