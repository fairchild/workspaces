/*
 * The pairing handshake contract: POST proves token possession and records
 * the ack (from the phone, so any origin); GET reports the latest ack to the
 * desktop poller over loopback only, and never leaks the token.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { GET, POST } from "./route";

let dataDir: string;

function getRequest(host = "localhost:3140"): Request {
	return new Request("http://localhost:3140/api/pairing/ack", { headers: { host } });
}

function postRequest(body: unknown): Request {
	return new Request("http://localhost:3140/api/pairing/ack", {
		method: "POST",
		headers: { "content-type": "application/json", "user-agent": "WorkSpaces-iOS-test" },
		body: JSON.stringify(body),
	});
}

describe("/api/pairing/ack", () => {
	beforeEach(() => {
		dataDir = mkdtempSync(path.join(tmpdir(), "pairing-ack-"));
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "1");
		vi.stubEnv("WEB_NEXT_DATA_DIR", dataDir);
		vi.stubEnv("WEB_NEXT_LOCAL_TOKEN", "the-minted-token");
	});

	afterEach(() => {
		vi.unstubAllEnvs();
		rmSync(dataDir, { recursive: true, force: true });
	});

	test("GET reports null before any pairing", async () => {
		await expect(GET(getRequest()).then((r) => r.json())).resolves.toEqual({
			pairedAt: null,
			userAgent: "",
		});
	});

	test("POST with the minted token records an ack GET then reports", async () => {
		const post = await POST(postRequest({ token: "the-minted-token" }));
		expect(post.status).toBe(200);
		const body = await GET(getRequest()).then((r) => r.json());
		expect(body.userAgent).toBe("WorkSpaces-iOS-test");
		expect(typeof body.pairedAt).toBe("string");
		expect(Number.isNaN(Date.parse(body.pairedAt))).toBe(false);
	});

	test("POST rejects a wrong token and records nothing", async () => {
		const post = await POST(postRequest({ token: "wrong" }));
		expect(post.status).toBe(401);
		await expect(GET(getRequest()).then((r) => r.json())).resolves.toEqual({
			pairedAt: null,
			userAgent: "",
		});
	});

	test("POST rejects a body without a token", async () => {
		expect((await POST(postRequest({}))).status).toBe(401);
	});

	test("GET refuses a proxied caller — pairing status is loopback-only", async () => {
		await POST(postRequest({ token: "the-minted-token" }));
		const proxied = await GET(getRequest("mac.tail.ts.net"));
		expect(proxied.status).toBe(403);
		await expect(proxied.json()).resolves.toEqual({
			error: "pairing status is loopback-only",
		});
		// …while the loopback poller still sees it.
		expect((await GET(getRequest("127.0.0.1:3140"))).status).toBe(200);
	});

	test("both verbs 404 outside local mode", async () => {
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "");
		expect((await GET(getRequest())).status).toBe(404);
		expect((await POST(postRequest({ token: "the-minted-token" }))).status).toBe(404);
	});
});
