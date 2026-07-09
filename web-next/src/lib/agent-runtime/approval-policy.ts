/*
 * Session approval policy classification for provider tool calls. The broker
 * owns waiting and durability; this module answers the small policy question:
 * whether a named tool must pause for user approval before it runs.
 */
export type ApprovalPolicy = "auto" | "ask-writes" | "ask-all";

const READ_CLASS_TOOLS = new Set([
	"Read",
	"Grep",
	"Glob",
	"LS",
	"WebFetch",
	"WebSearch",
]);

export function needsApproval(
	policy: ApprovalPolicy,
	toolName: string | undefined,
): boolean {
	if (policy === "auto") return false;
	if (policy === "ask-all") return true;
	const normalized = (toolName ?? "").trim();
	return !READ_CLASS_TOOLS.has(normalized);
}
