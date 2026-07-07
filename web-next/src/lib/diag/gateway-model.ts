/*
 * Translates a selectable Claude Code model id (`agent-runtime/models.ts` —
 * the CLI's own id shape, e.g. `claude-haiku-4-5`) into the AI Gateway's
 * OpenAI-compatible model string (e.g. `anthropic/claude-haiku-4.5`) for
 * `/api/diag/gateway`. These are two different id namespaces for the same
 * models: the CLI harness forwards its id straight to `claude --model`,
 * while the gateway's chat/completions endpoint wants a provider-prefixed,
 * dot-versioned string. The only structural difference between the two
 * shapes is the trailing `-<major>-<minor>` version suffix becoming
 * `-<major>.<minor>` — verified against all four current ids, including the
 * pre-existing hardcoded gateway call this replaces (`claude-haiku-4-5` →
 * `anthropic/claude-haiku-4.5`).
 */
import { isSelectableModel } from "@/lib/agent-runtime/models";

const TRAILING_TWO_PART_VERSION = /-(\d+)-(\d+)$/;

export function toGatewayModelId(id: string): string {
	return `anthropic/${id.replace(TRAILING_TWO_PART_VERSION, "-$1.$2")}`;
}

/** Validates against the single source of truth before translating. */
export function resolveGatewayModel(
	id: string,
): { ok: true; gatewayModel: string } | { ok: false; error: string } {
	if (!isSelectableModel(id)) {
		return { ok: false, error: `unknown model: ${id}` };
	}
	return { ok: true, gatewayModel: toGatewayModelId(id) };
}
