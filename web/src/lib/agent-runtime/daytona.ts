import type {
	ComputeProvider,
	ComputeProviderAvailability,
	ComputeProviderDescriptor,
	SandboxRequest,
	SandboxResult,
	StreamChunk,
} from "./types";

/**
 * Daytona cloud sandbox provider — stub.
 * Will port Swift DaytonaBackend REST calls (app.daytona.io/api) to TypeScript.
 */
export class DaytonaProvider implements ComputeProvider {
	readonly descriptor: ComputeProviderDescriptor = {
		id: "daytona",
		displayName: "Daytona",
		maxSessionDuration: 4 * 60 * 60 * 1000, // 4 hours
		supportsSnapshot: false,
		supportsStreaming: true,
	};

	async checkAvailability(): Promise<ComputeProviderAvailability> {
		return { available: false, reason: "Daytona provider not yet implemented" };
	}

	async createSandbox(_request: SandboxRequest): Promise<SandboxResult> {
		throw new Error("Daytona provider not yet implemented");
	}

	async *streamOutput(_instanceId: string): AsyncGenerator<StreamChunk> {
		yield { type: "error", content: "Daytona provider not yet implemented" };
	}

	async sendMessage(_instanceId: string, _message: string): Promise<void> {
		throw new Error("Daytona provider not yet implemented");
	}

	async destroySandbox(_instanceId: string): Promise<void> {
		throw new Error("Daytona provider not yet implemented");
	}
}
