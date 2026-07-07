/*
 * GET /api/diag/gateway — auth gating (unchanged), model-id validation
 * against agent-runtime/models.ts, and the gateway-model translation used in
 * the outgoing AI Gateway call. `getAuthState` and `fetch` are mocked; no
 * real network call or credential is involved.
 */
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { getAuthState } from "@/lib/auth/auth-state";

vi.mock("@/lib/auth/auth-state", () => ({
	getAuthState: vi.fn(),
}));

const AUTHORIZED = {
	kind: "authorized" as const,
	user: { login: "fairchild", name: "Fairchild" },
};

const originalFetch = global.fetch;
const originalKey = process.env.AI_GATEWAY_API_KEY;

beforeEach(() => {
	vi.mocked(getAuthState).mockResolvedValue(AUTHORIZED);
	process.env.AI_GATEWAY_API_KEY = "test-key";
});

afterEach(() => {
	global.fetch = originalFetch;
	process.env.AI_GATEWAY_API_KEY = originalKey;
	vi.clearAllMocks();
});

async function get(url: string) {
	const { GET } = await import("./route");
	return GET(new Request(url));
}

describe("GET /api/diag/gateway", () => {
	test("401s when unauthenticated (auth gate unchanged)", async () => {
		vi.mocked(getAuthState).mockResolvedValue({ kind: "unauthenticated" });
		const res = await get("http://test/api/diag/gateway");
		expect(res.status).toBe(401);
	});

	test("403s when signed in but not allowlisted", async () => {
		vi.mocked(getAuthState).mockResolvedValue({ kind: "forbidden", login: "nope" });
		const res = await get("http://test/api/diag/gateway");
		expect(res.status).toBe(403);
	});

	test("rejects an unknown model id with 400, never reaching the gateway", async () => {
		const fetchSpy = vi.fn();
		global.fetch = fetchSpy as unknown as typeof fetch;
		const res = await get("http://test/api/diag/gateway?model=gpt-5");
		expect(res.status).toBe(400);
		expect((await res.json()).error).toMatch(/unknown model/);
		expect(fetchSpy).not.toHaveBeenCalled();
	});

	test("defaults to DEFAULT_MODEL when no model param is given (#815 posture probe unaffected)", async () => {
		const fetchSpy = vi.fn().mockResolvedValue(
			new Response(JSON.stringify({ model: "anthropic/claude-fable-5", choices: [{ message: { content: "gateway live" } }] }), {
				status: 200,
			}),
		);
		global.fetch = fetchSpy as unknown as typeof fetch;
		const res = await get("http://test/api/diag/gateway");
		expect(res.status).toBe(200);
		const body = await res.json();
		expect(body.model).toBe("claude-fable-5");
		expect(body.gatewayModel).toBe("anthropic/claude-fable-5");
	});

	test("translates a selected model id to its gateway string in the outgoing call", async () => {
		const fetchSpy = vi.fn().mockResolvedValue(
			new Response(JSON.stringify({ choices: [{ message: { content: "gateway live" } }] }), { status: 200 }),
		);
		global.fetch = fetchSpy as unknown as typeof fetch;
		const res = await get("http://test/api/diag/gateway?model=claude-haiku-4-5");
		expect(res.status).toBe(200);
		const body = await res.json();
		expect(body.model).toBe("claude-haiku-4-5");
		expect(body.gatewayModel).toBe("anthropic/claude-haiku-4.5");

		const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
		const sentBody = JSON.parse(init.body as string);
		expect(sentBody.model).toBe("anthropic/claude-haiku-4.5");
	});

	test("missing AI_GATEWAY_API_KEY reports 500 with the exact message the validation stage gates on", async () => {
		delete process.env.AI_GATEWAY_API_KEY;
		const res = await get("http://test/api/diag/gateway?model=claude-sonnet-5");
		expect(res.status).toBe(500);
		expect((await res.json()).error).toBe("AI_GATEWAY_API_KEY is not set in this deployment");
	});

	test("an upstream gateway error is returned verbatim with the requested model", async () => {
		const fetchSpy = vi.fn().mockResolvedValue(
			new Response(JSON.stringify({ error: "rate limited" }), { status: 429 }),
		);
		global.fetch = fetchSpy as unknown as typeof fetch;
		const res = await get("http://test/api/diag/gateway?model=claude-opus-4-8");
		expect(res.status).toBe(502);
		const body = await res.json();
		expect(body.ok).toBe(false);
		expect(body.model).toBe("claude-opus-4-8");
		expect(body.status).toBe(429);
	});
});
