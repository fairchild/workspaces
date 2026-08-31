/*
 * The sign-in bounce contract: a proxied redemption records the ack, a
 * loopback redemption (the desktop's own webview) does not, the redirect is
 * relative and sanitized, and nothing works signed out or outside local mode.
 */
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { readPairingAck } from "@/lib/pairing/ack-store";
import { GET } from "./route";

let dataDir: string;

function redeemRequest(options: {
	host: string;
	next?: string;
	cookie?: string;
}): NextRequest {
	const query = options.next ? `?next=${encodeURIComponent(options.next)}` : "";
	return new NextRequest(`http://placeholder.test/api/pairing/redeemed${query}`, {
		headers: {
			host: options.host,
			"user-agent": "WorkSpaces-iOS-test",
			...(options.cookie ? { cookie: options.cookie } : {}),
		},
	});
}

const VALID_COOKIE = "web-next-local-session=the-minted-token";

describe("/api/pairing/redeemed", () => {
	beforeEach(() => {
		dataDir = mkdtempSync(path.join(tmpdir(), "pairing-redeemed-"));
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "1");
		vi.stubEnv("WEB_NEXT_DATA_DIR", dataDir);
		vi.stubEnv("WEB_NEXT_LOCAL_TOKEN", "the-minted-token");
	});

	afterEach(() => {
		vi.unstubAllEnvs();
		rmSync(dataDir, { recursive: true, force: true });
	});

	test("a proxied redemption records the ack and redirects relative", async () => {
		const response = await GET(
			redeemRequest({ host: "mac.tail.ts.net", next: "/sessions/abc", cookie: VALID_COOKIE }),
		);
		expect(response.status).toBe(307);
		expect(response.headers.get("location")).toBe("/sessions/abc");
		const ack = await readPairingAck();
		expect(ack.userAgent).toBe("WorkSpaces-iOS-test");
		expect(typeof ack.pairedAt).toBe("string");
	});

	test("a loopback redemption redirects but records nothing — not a phone pairing", async () => {
		const response = await GET(
			redeemRequest({ host: "localhost:3140", next: "/", cookie: VALID_COOKIE }),
		);
		expect(response.status).toBe(307);
		await expect(readPairingAck()).resolves.toEqual({ pairedAt: null, userAgent: "" });
	});

	test("an unsafe next falls back to /", async () => {
		const response = await GET(
			redeemRequest({ host: "mac.tail.ts.net", next: "https://evil.com/x", cookie: VALID_COOKIE }),
		);
		expect(response.headers.get("location")).toBe("/");
	});

	test("no valid cookie means 401 and no ack", async () => {
		const response = await GET(redeemRequest({ host: "mac.tail.ts.net", next: "/" }));
		expect(response.status).toBe(401);
		await expect(readPairingAck()).resolves.toEqual({ pairedAt: null, userAgent: "" });
	});

	test("404 outside local mode", async () => {
		vi.stubEnv("WEB_NEXT_LOCAL_MODE", "");
		const response = await GET(
			redeemRequest({ host: "mac.tail.ts.net", next: "/", cookie: VALID_COOKIE }),
		);
		expect(response.status).toBe(404);
	});
});
