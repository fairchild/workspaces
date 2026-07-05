/*
 * GET /api/diag/gateway — auth-gated diagnostic probe: makes one tiny real
 * model call through the AI Gateway to prove the credential, billing, and
 * model routing work in this deployment, before the real runtime (#750)
 * depends on them. Returns the model's reply or the upstream error verbatim.
 */
import { getAuthState } from "@/lib/auth/auth-state";

export async function GET() {
	const auth = await getAuthState();
	if (auth.kind !== "authorized") {
		return Response.json(
			{ error: "not signed in as the allowed user" },
			{ status: auth.kind === "unauthenticated" ? 401 : 403 },
		);
	}

	const key = process.env.AI_GATEWAY_API_KEY;
	if (!key) {
		return Response.json(
			{ ok: false, error: "AI_GATEWAY_API_KEY is not set in this deployment" },
			{ status: 500 },
		);
	}

	const startedAt = Date.now();
	const response = await fetch("https://ai-gateway.vercel.sh/v1/chat/completions", {
		method: "POST",
		headers: {
			Authorization: `Bearer ${key}`,
			"Content-Type": "application/json",
		},
		body: JSON.stringify({
			model: "anthropic/claude-haiku-4.5",
			messages: [{ role: "user", content: "Reply with exactly: gateway live" }],
			max_tokens: 10,
		}),
	});

	const body = await response.json().catch(() => null);
	if (!response.ok) {
		return Response.json(
			{ ok: false, status: response.status, upstream: body },
			{ status: 502 },
		);
	}

	return Response.json({
		ok: true,
		model: body?.model,
		reply: body?.choices?.[0]?.message?.content,
		usage: body?.usage,
		latencyMs: Date.now() - startedAt,
	});
}
