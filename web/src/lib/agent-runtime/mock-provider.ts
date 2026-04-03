import ms from "ms";
import type {
	ComputeProvider,
	ComputeProviderAvailability,
	ComputeProviderDescriptor,
	SandboxRequest,
	SandboxResult,
	SnapshotCapable,
	StreamChunk,
} from "./types";

let counter = 0;

/** Active mock instances: instanceId → stored message. */
const instances = new Map<string, string>();

/** Instances that were created via restoreSnapshot. */
const restoredInstances = new Set<string>();

/** Snapshot store: snapshotId → message at time of snapshot. */
const snapshots = new Map<string, string>();

export class MockComputeProvider implements ComputeProvider, SnapshotCapable {
	readonly descriptor: ComputeProviderDescriptor = {
		id: "mock",
		displayName: "Mock Provider",
		maxSessionDuration: ms("1h"),
		supportsSnapshot: true,
		supportsStreaming: true,
	};

	async checkAvailability(): Promise<ComputeProviderAvailability> {
		return { available: true };
	}

	async createSandbox(request: SandboxRequest): Promise<SandboxResult> {
		const instanceId = `mock-${counter++}`;
		instances.set(instanceId, request.message);
		return { instanceId, status: "ready" };
	}

	async *streamOutput(instanceId: string): AsyncGenerator<StreamChunk> {
		const message = instances.get(instanceId) ?? "";
		const prefix = restoredInstances.has(instanceId) ? "[restored] " : "";
		yield {
			type: "text",
			content: `${prefix}Mock agent response. You said: ${message}`,
		};
		yield { type: "done", content: "" };
	}

	async sendMessage(instanceId: string, message: string): Promise<void> {
		instances.set(instanceId, message);
	}

	async destroySandbox(instanceId: string): Promise<void> {
		instances.delete(instanceId);
	}

	async createSnapshot(instanceId: string): Promise<string> {
		const snapshotId = `mock-snap-${counter++}`;
		const message = instances.get(instanceId) ?? "";
		snapshots.set(snapshotId, message);
		instances.delete(instanceId);
		return snapshotId;
	}

	async restoreSnapshot(snapshotId: string): Promise<SandboxResult> {
		const instanceId = `mock-restored-${counter++}`;
		const message = snapshots.get(snapshotId) ?? "";
		instances.set(instanceId, message);
		restoredInstances.add(instanceId);
		return { instanceId, status: "ready" };
	}
}
