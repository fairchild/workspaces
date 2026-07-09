/*
 * GET /api/healthz — the response is the contract (embedded-native-contract,
 * #987): 200, `{ ok: true, localMode: <boolean> }`, and nothing else.
 */
import { afterEach, describe, expect, test, vi } from "vitest";
import { GET } from "./route";

afterEach(() => {
	vi.unstubAllEnvs();
});

describe("GET /api/healthz", () => {
	test("answers 200 {ok:true, localMode:false} outside local mode", async () => {
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "");
		const response = GET();
		expect(response.status).toBe(200);
		await expect(response.json()).resolves.toEqual({ ok: true, localMode: false });
	});

	test("reports localMode:true under WEB_NEXT_LOCAL_MODE=1 and stays constant otherwise", async () => {
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "1");
		const body = await GET().json();
		expect(body).toEqual({ ok: true, localMode: true });
		expect(Object.keys(body).sort()).toEqual(["localMode", "ok"]);
	});
});
