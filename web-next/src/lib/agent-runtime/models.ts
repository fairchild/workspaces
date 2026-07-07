/*
 * Single source of truth for selectable Claude models — the picker
 * (session-view/status-line), the session-creation default, and TurnRequest
 * threading all read this one list, so #816's validation stage can later read
 * the same set instead of a second copy.
 *
 * Grounded against the sandboxed Claude Code harness's own model resolution,
 * not invented: `createClaudeCode({ model })` (@ai-sdk/harness-claude-code)
 * forwards the string unchanged onto `claudeSdk.query({ options: { model } })`
 * inside the sandbox bridge — no enum/allowlist at that layer — and the
 * installed `claude` CLI (`--model <model>`, `claude --help`) documents
 * exactly these ids as current: aliases `fable` / `opus` / `sonnet` / `haiku`,
 * full ids `claude-fable-5`, `claude-opus-4-8`, `claude-sonnet-5`,
 * `claude-haiku-4-5`. Full ids are stored (not bare aliases) so the value in
 * `sessions.model` is unambiguous. Fable 5 is the CLI's own "most advanced
 * generally available model" — the literal "current best", so it is the
 * default new sessions stamp.
 */
export interface ModelOption {
	id: string;
	label: string;
	description: string;
}

export const MODEL_OPTIONS: readonly ModelOption[] = [
	{
		id: "claude-fable-5",
		label: "Fable 5",
		description: "Most capable — for hard or high-stakes changes.",
	},
	{
		id: "claude-opus-4-8",
		label: "Opus 4.8",
		description: "Deep reasoning for complex work.",
	},
	{
		id: "claude-sonnet-5",
		label: "Sonnet 5",
		description: "Fast and capable — a strong everyday default.",
	},
	{
		id: "claude-haiku-4-5",
		label: "Haiku 4.5",
		description: "Fastest and cheapest, for small or routine turns.",
	},
];

/** The current best model — new sessions stamp this unless overridden. */
export const DEFAULT_MODEL: string = MODEL_OPTIONS[0].id;

export function isSelectableModel(id: string): boolean {
	return MODEL_OPTIONS.some((option) => option.id === id);
}

/** Display label for a model id; falls back to the raw id if unrecognized
 * (an org-restricted or retired model a session was created with earlier). */
export function modelLabel(id: string): string {
	return MODEL_OPTIONS.find((option) => option.id === id)?.label ?? id;
}
