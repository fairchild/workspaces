import type { Workspace } from "./types";

export interface SyncState {
	workspaces: Workspace[];
	syncedAt: string;
}

/** In-memory store keyed by user ID. Native app syncs replace the full list. */
const store = new Map<string, SyncState>();

export function syncWorkspaces(userId: string, workspaces: Workspace[]): void {
	store.set(userId, {
		workspaces,
		syncedAt: new Date().toISOString(),
	});
}

export function getWorkspaces(userId: string): SyncState | null {
	return store.get(userId) ?? null;
}
