/*
 * I/O for the #818 real-agentic-turn validation stage: an HTTP client over
 * the session APIs (create → chat → poll the durable log → delete) plus the
 * stage wrapper validate.mjs calls. All verdict logic lives in
 * real-turn-core.mjs; this file only moves bytes — every request carries the
 * Vercel protection-bypass header when present, redacts secrets from any
 * error text, and never throws on HTTP errors.
 */
import crypto from "node:crypto";
import { DEFAULT_MODEL } from "../src/lib/agent-runtime/models.ts";
import {
	classifyPreflightGate,
	runHostTurnProbe,
	runRealTurnProbe,
} from "./real-turn-core.mjs";
import { redactSecrets } from "./validate-core.mjs";

/** Ordinary API calls; generous, but not the turn itself. */
const REQUEST_TIMEOUT_MS = 30_000;
/** The chat POST — the route's own maxDuration is 300s. */
const CHAT_TIMEOUT_MS = 330_000;

function secretsToRedact(env) {
	return [env.VERCEL_AUTOMATION_BYPASS_SECRET, env.WEB_NEXT_VALIDATION_SESSION];
}

async function request(baseUrl, pathname, { cookie, env, timeoutMs = REQUEST_TIMEOUT_MS, ...init } = {}) {
	const bypass = env.VERCEL_AUTOMATION_BYPASS_SECRET;
	try {
		const res = await fetch(`${baseUrl}${pathname}`, {
			...init,
			headers: {
				...(bypass ? { "x-vercel-protection-bypass": bypass } : {}),
				...(cookie ? { cookie } : {}),
				...init.headers,
			},
			redirect: "manual",
			signal: AbortSignal.timeout(timeoutMs),
		});
		const text = await res.text().catch(() => "");
		let body;
		try {
			body = JSON.parse(text);
		} catch {
			body = undefined;
		}
		return { status: res.status, body };
	} catch (error) {
		return {
			status: 0,
			body: { error: redactSecrets(String(error), secretsToRedact(env)) },
		};
	}
}

/** The injected client runRealTurnProbe drives (see real-turn-core.mjs). */
export function createRealTurnClient(baseUrl, cookie, env) {
	return {
		createSession: (body) =>
			request(baseUrl, "/api/sessions", {
				cookie,
				env,
				method: "POST",
				headers: { "content-type": "application/json" },
				body: JSON.stringify(body),
			}),
		sendChat: async (id, text) => {
			// The chat response streams the turn; the durable log is what the
			// probe asserts on, so the body is consumed and discarded — reading
			// it keeps the connection (and a serverless invocation) alive while
			// the poll below follows the log.
			const bypass = env.VERCEL_AUTOMATION_BYPASS_SECRET;
			try {
				const res = await fetch(`${baseUrl}/api/sessions/${id}/chat`, {
					method: "POST",
					headers: {
						...(bypass ? { "x-vercel-protection-bypass": bypass } : {}),
						...(cookie ? { cookie } : {}),
						"content-type": "application/json",
					},
					body: JSON.stringify({ text }),
					redirect: "manual",
					signal: AbortSignal.timeout(CHAT_TIMEOUT_MS),
				});
				if (res.status !== 200) {
					const text = await res.text().catch(() => "");
					let body;
					try {
						body = JSON.parse(text);
					} catch {
						body = undefined;
					}
					return { status: res.status, body };
				}
				// Drain in the background; failures here are the stream ending.
				res.text().catch(() => {});
				return { status: 200, body: undefined };
			} catch (error) {
				return {
					status: 0,
					body: { error: redactSecrets(String(error), secretsToRedact(env)) },
				};
			}
		},
		getSession: (id) => request(baseUrl, `/api/sessions/${id}`, { cookie, env }),
		deleteSession: (id) =>
			request(baseUrl, `/api/sessions/${id}`, { cookie, env, method: "DELETE" }),
	};
}

/**
 * The stage: preflight-gate the target's runtime credentials (cheap, no
 * sandbox), then run exactly one scripted coding turn and assert the six #818
 * contract points from the durable log. Spend: one small real turn per run —
 * the sanctioned cadence is the scheduled daily lane plus on-demand runs.
 */
export async function realTurnStage(baseUrl, cookie, env, options = {}) {
	const id = "real agentic turn (#818)";
	const preflight = await request(baseUrl, "/api/diag/preflight", {
		cookie,
		env,
		timeoutMs: 120_000,
	});
	const gate = classifyPreflightGate(preflight);
	if (gate.skip) return { id, status: "skip", reason: gate.reason };
	if (gate.fail) {
		return {
			id,
			status: "run",
			checks: [{ id: "runtime_preflight", status: "fail", detail: gate.detail }],
		};
	}

	try {
		if (gate.provider !== "vercel" && gate.provider !== "host") {
			return {
				id,
				status: "skip",
				reason: `provider ${JSON.stringify(gate.provider)} has no real-turn validation contract`,
			};
		}
		const runProbe = gate.provider === "host" ? runHostTurnProbe : runRealTurnProbe;
		const result = await runProbe(createRealTurnClient(baseUrl, cookie, env), {
			nonce: crypto.randomBytes(8).toString("hex"),
			defaultModel: DEFAULT_MODEL,
			...options,
		});
		// Belt over the client's own redaction: no check detail reaches the
		// console/JSON/report carrying a credential, whatever produced it.
		if (result.checks) {
			result.checks = result.checks.map((c) => ({
				...c,
				detail: redactSecrets(String(c.detail ?? ""), secretsToRedact(env)),
			}));
		}
		return {
			id: gate.provider === "host" ? "real host-provider turn (#1014)" : id,
			...result,
		};
	} catch (error) {
		// The probe's own teardown already ran (its `finally`); an escaped error
		// becomes a failing check rather than crashing the whole run.
		return {
			id,
			status: "run",
			checks: [
				{
					id: "probe_crashed",
					status: "fail",
					detail: redactSecrets(String(error), secretsToRedact(env)),
				},
			],
		};
	}
}
