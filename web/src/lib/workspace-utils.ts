import type { Workspace } from "./types";

export const VALID_STATUSES: Set<string> = new Set([
	"provisioning",
	"active",
	"stopped",
	"archived",
]);

export function isWorkspace(v: unknown): v is Workspace {
	if (typeof v !== "object" || v === null) return false;
	const o = v as Record<string, unknown>;
	return (
		typeof o.id === "string" &&
		typeof o.name === "string" &&
		typeof o.path === "string" &&
		typeof o.status === "string" &&
		VALID_STATUSES.has(o.status) &&
		typeof o.backendIdentifier === "string"
	);
}
