/*
 * GET /api/diag/gateway[?model=<id>] — auth-gated diagnostic probe: makes one
 * tiny real model call through the AI Gateway to prove the credential,
 * billing, and model routing work in this deployment, before the real
 * runtime (#750) depends on them. `model` must be one of the selectable ids
 * in `agent-runtime/models.ts` (the single source of truth the picker and
 * session creation also read) — defaults to `DEFAULT_MODEL` when omitted, so
 * the #815 posture stage's existing bare `GET /api/diag/gateway` probe is
 * unaffected. #816's validation stage calls this once per selectable model to
 * prove selection actually routes, not just a hardcoded default. Returns the
 * model's reply or the upstream error verbatim.
 */
import { DEFAULT_MODEL } from "@/lib/agent-runtime/models";
import { getAuthState } from "@/lib/auth/auth-state";
import { resolveGatewayModel } from "@/lib/diag/gateway-model";

export async function GET(request: Request) {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const requestedModel = new URL(request.url).searchParams.get("model") ?? DEFAULT_MODEL;
	const resolved = resolveGatewayModel(requestedModel);
	if (!resolved.ok) {
		return Response.json({ ok: false, error: resolved.error }, { status: 400 });
	}

	const key = process.env.AI_GATEWAY_API_KEY;
	if (!key) {
		return Response.json(
			{ ok: false, error: "AI_GATEWAY_API_KEY is not set in this deployment" },
			{ status: 500 },
		);
	}

	const startedAt = Date.now();
	let response: Response;
	try {
		response = await fetch("https://ai-gateway.vercel.sh/v1/chat/completions", {
			method: "POST",
			headers: {
				Authorization: `Bearer ${key}`,
				"Content-Type": "application/json",
			},
			body: JSON.stringify({
				model: resolved.gatewayModel,
				messages: [{ role: "user", content: "Reply with exactly: gateway live" }],
				// Reasoning models (fable-5) spend completion budget on thinking
				// before any text — 10 tokens yields an empty reply and a false red.
				max_tokens: 400,
			}),
		});
	} catch (error) {
		// A malformed key value makes fetch throw an invalid-header error whose
		// message echoes `Bearer <value>` — report the error CLASS only, never
		// the message, so the credential can't leak into logs or the response.
		const name = error instanceof Error ? error.name : "Error";
		return Response.json(
			{ ok: false, model: requestedModel, error: `gateway request failed before a response (${name})` },
			{ status: 502 },
		);
	}

	const body = await response.json().catch(() => null);
	if (!response.ok) {
		return Response.json(
			{ ok: false, model: requestedModel, status: response.status, upstream: body },
			{ status: 502 },
		);
	}

	return Response.json({
		ok: true,
		model: requestedModel,
		gatewayModel: resolved.gatewayModel,
		reply: body?.choices?.[0]?.message?.content,
		usage: body?.usage,
		latencyMs: Date.now() - startedAt,
	});
}
