/*
 * Ported with the implementation from web/src/lib/__tests__/session-cookie.test.ts —
 * the freshness verdicts are a behavior contract middleware relies on.
 */
import { describe, expect, it } from "vitest";
import { evaluateSessionFreshness } from "./session-cookie";

const SECRET = "test-secret-for-session-cookie-1234567890";
const TOKEN = "better-auth.session_token";
const DATA = "better-auth.session_data";

const encoder = new TextEncoder();

function base64UrlNoPad(bytes: Uint8Array): string {
	let binary = "";
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary)
		.replace(/\+/g, "-")
		.replace(/\//g, "_")
		.replace(/=+$/, "");
}

function base64UrlEncodeString(value: string): string {
	return base64UrlNoPad(encoder.encode(value));
}

async function hmacSha256(secret: string, data: string): Promise<string> {
	const key = await crypto.subtle.importKey(
		"raw",
		encoder.encode(secret),
		{ name: "HMAC", hash: "SHA-256" },
		false,
		["sign"],
	);
	const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(data));
	return base64UrlNoPad(new Uint8Array(signature));
}

/**
 * Build a compact-strategy `session_data` cookie value the same way Better
 * Auth's `setCookieCache` does: `base64url(JSON({ session, expiresAt, signature }))`
 * where `signature = HMAC-SHA256(secret, JSON({ ...session, expiresAt }))`.
 */
async function buildSessionDataCookie(opts: {
	secret: string;
	expiresAt: number;
	tamper?: boolean;
}): Promise<string> {
	const session = {
		session: {
			id: "session-1",
			userId: "user-1",
			expiresAt: new Date(Date.now() + 3_600_000).toISOString(),
		},
		user: { id: "user-1", email: "user@example.com" },
		updatedAt: Date.now(),
		version: "1",
	};
	let signature = await hmacSha256(
		opts.secret,
		JSON.stringify({ ...session, expiresAt: opts.expiresAt }),
	);
	if (opts.tamper) {
		// Flip the FIRST character, which carries 6 fully-significant bits, so
		// the tampered string always decodes to different signature bytes. Do
		// not tamper the 43rd (final) char: it encodes only 4 significant bits
		// (the low 2 are padding that decoders discard), so e.g. 'A'->'B' there
		// decodes to identical bytes and HMAC verification still passes —
		// a 1-in-16 flake, since the signed payload embeds Date.now().
		signature = `${signature.startsWith("A") ? "B" : "A"}${signature.slice(1)}`;
	}
	return base64UrlEncodeString(
		JSON.stringify({ session, expiresAt: opts.expiresAt, signature }),
	);
}

function requestWithCookies(cookies: Record<string, string>): Request {
	const header = Object.entries(cookies)
		.map(([name, value]) => `${name}=${value}`)
		.join("; ");
	return new Request("https://spaces.example/", {
		headers: header ? { cookie: header } : {},
	});
}

describe("evaluateSessionFreshness", () => {
	it("returns 'fresh' for a valid, unexpired signed cookie cache", async () => {
		const sessionData = await buildSessionDataCookie({
			secret: SECRET,
			expiresAt: Date.now() + 5 * 60_000,
		});
		const request = requestWithCookies({
			[TOKEN]: "any-token-value",
			[DATA]: sessionData,
		});
		expect(await evaluateSessionFreshness(request, { secret: SECRET })).toBe(
			"fresh",
		);
	});

	it("returns 'stale' when the cookie cache has expired", async () => {
		const sessionData = await buildSessionDataCookie({
			secret: SECRET,
			expiresAt: Date.now() - 1_000,
		});
		const request = requestWithCookies({
			[TOKEN]: "any-token-value",
			[DATA]: sessionData,
		});
		expect(await evaluateSessionFreshness(request, { secret: SECRET })).toBe(
			"stale",
		);
	});

	it("returns 'stale' when the cookie-cache signature does not verify", async () => {
		const sessionData = await buildSessionDataCookie({
			secret: SECRET,
			expiresAt: Date.now() + 5 * 60_000,
			tamper: true,
		});
		const request = requestWithCookies({
			[TOKEN]: "any-token-value",
			[DATA]: sessionData,
		});
		expect(await evaluateSessionFreshness(request, { secret: SECRET })).toBe(
			"stale",
		);
	});

	it("returns 'stale' when the cookie cache is present but malformed", async () => {
		// A base64url payload that decodes to non-JSON — a corrupt/truncated
		// cache cookie. getCookieCache returns null before touching the secret.
		const request = requestWithCookies({
			[TOKEN]: "any-token-value",
			[DATA]: base64UrlEncodeString("not-a-valid-session-payload"),
		});
		expect(await evaluateSessionFreshness(request, { secret: SECRET })).toBe(
			"stale",
		);
	});

	it("returns 'stale' when no session token cookie is present", async () => {
		const request = requestWithCookies({});
		expect(await evaluateSessionFreshness(request, { secret: SECRET })).toBe(
			"stale",
		);
	});

	it("returns 'indeterminate' when the token is present but the cookie cache is absent", async () => {
		// The short-TTL cache lapsed while the longer-lived token may still be
		// valid — defer to the server gate rather than log the user out.
		const request = requestWithCookies({ [TOKEN]: "any-token-value" });
		expect(await evaluateSessionFreshness(request, { secret: SECRET })).toBe(
			"indeterminate",
		);
	});

	it("returns 'indeterminate' when cookie-cache verification throws (fail-open)", async () => {
		// A value that cannot be base64-decoded makes getCookieCache throw; a
		// verification error must never hard-fail middleware.
		const request = requestWithCookies({
			[TOKEN]: "any-token-value",
			[DATA]: "!!!not-valid-base64!!!",
		});
		expect(await evaluateSessionFreshness(request, { secret: SECRET })).toBe(
			"indeterminate",
		);
	});

	it("verifies the secure cookie-cache name when present", async () => {
		const sessionData = await buildSessionDataCookie({
			secret: SECRET,
			expiresAt: Date.now() + 5 * 60_000,
		});
		const request = requestWithCookies({
			"__Secure-better-auth.session_token": "any-token-value",
			"__Secure-better-auth.session_data": sessionData,
		});
		expect(await evaluateSessionFreshness(request, { secret: SECRET })).toBe(
			"fresh",
		);
	});
});
