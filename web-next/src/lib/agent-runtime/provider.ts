/*
 * The compute-provider seam at turn granularity: a provider takes the user's
 * message and yields the StreamChunks of one agent turn. This is the surface
 * the transcript pipeline is written against — sessions name their provider
 * (sessions.provider), and #749+ swap real sandbox-backed providers in behind
 * the same StreamChunk protocol shared with the legacy web/ runtime.
 */
import { mockProvider } from "./mock-provider";
import type { StreamChunk } from "./stream-chunk";
import { vercelProvider } from "./vercel-provider";

export interface TurnRequest {
	sessionId: string;
	userMessage: string;
}

export interface ComputeProvider {
	/** Provider id as stored in sessions.provider ("mock" | "vercel" | …). */
	readonly id: string;
	/** Runs one agent turn, yielding chunks as they are produced. */
	runTurn(request: TurnRequest): AsyncIterable<StreamChunk>;
}

const providers: Record<string, ComputeProvider> = {
	[mockProvider.id]: mockProvider,
	[vercelProvider.id]: vercelProvider,
};

export function getProvider(id: string): ComputeProvider {
	const provider = providers[id];
	if (!provider) throw new Error(`Unknown compute provider: ${id}`);
	return provider;
}
