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

/**
 * A parked harness session to reconnect on this turn: the harness session id
 * plus the JSON resume payload a prior turn's `detach()` returned. Providers
 * that don't resume (mock) ignore it; the real provider reconnects the warm
 * sandbox and continues the conversation.
 */
export interface SessionResumeHandle {
	harnessSessionId: string;
	resumeState: string;
}

export interface TurnRepo {
	fullName: string;
	defaultBranch: string | null;
}

export interface TurnRequest {
	sessionId: string;
	userMessage: string;
	/**
	 * The repo selected when the session was created. Repo-less sessions (for
	 * example POST /api/sessions probes) leave this null/undefined and let the
	 * provider use its configured fallback.
	 */
	repo?: TurnRepo | null;
	/** Prior parked session to resume, or null/undefined for a fresh turn. */
	resume?: SessionResumeHandle | null;
	/**
	 * Compact replay of prior session dialogue for providers that must boot a
	 * fresh model conversation after their warm resume path fails. Omitted on a
	 * genuine first turn.
	 */
	priorContext?: string | null;
	/**
	 * The session's selected Claude model id (see `./models.ts`). Providers
	 * that drive a real model (vercel) thread it into the harness; providers
	 * that don't (mock) record it for testability but otherwise ignore it.
	 */
	model?: string;
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
