import crypto from "node:crypto";
import { describe, expect, it } from "vitest";
import { generateAppJWT, normalizePrivateKey } from "./github-app";

// A throwaway RSA keypair — the App private-key handling and RS256 signing are
// the error-prone parts (base64 vs PEM, correct signature), so verify them
// end-to-end without any network.
const { privateKey, publicKey } = crypto.generateKeyPairSync("rsa", {
	modulusLength: 2048,
	publicKeyEncoding: { type: "spki", format: "pem" },
	privateKeyEncoding: { type: "pkcs8", format: "pem" },
});

describe("normalizePrivateKey", () => {
	it("passes a real multi-line PEM through unchanged", () => {
		expect(normalizePrivateKey(privateKey)).toBe(privateKey.trim());
	});

	it("restores newlines from a single-line escaped PEM", () => {
		const escaped = privateKey.trim().replace(/\n/g, "\\n");
		expect(normalizePrivateKey(escaped)).toBe(privateKey.trim());
	});

	it("decodes a base64-encoded PEM (web-next's .env convention)", () => {
		const b64 = Buffer.from(privateKey).toString("base64");
		expect(normalizePrivateKey(b64)).toBe(privateKey);
	});
});

describe("generateAppJWT", () => {
	it("produces a three-part token with a valid RS256 signature and claims", () => {
		const jwt = generateAppJWT("123456", privateKey);
		const [header, payload, signature] = jwt.split(".");
		expect(header && payload && signature).toBeTruthy();

		const verifier = crypto.createVerify("RSA-SHA256");
		verifier.update(`${header}.${payload}`);
		expect(
			verifier.verify(publicKey, Buffer.from(signature, "base64url")),
		).toBe(true);

		const claims = JSON.parse(Buffer.from(payload, "base64url").toString());
		expect(claims.iss).toBe("123456");
		expect(claims.exp - claims.iat).toBe(660); // 10min window + 60s backdate
	});

	it("accepts a base64-encoded key (signature still verifies)", () => {
		const b64 = Buffer.from(privateKey).toString("base64");
		const jwt = generateAppJWT("123456", b64);
		const [header, payload, signature] = jwt.split(".");
		const verifier = crypto.createVerify("RSA-SHA256");
		verifier.update(`${header}.${payload}`);
		expect(
			verifier.verify(publicKey, Buffer.from(signature, "base64url")),
		).toBe(true);
	});
});
