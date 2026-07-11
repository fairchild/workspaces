import assert from "node:assert/strict";
import test from "node:test";
import worker, { MAX_UPLOAD_BYTES } from "./index.ts";

function env(overrides = {}) {
	return {
		EVIDENCE_UPLOAD_TOKEN: "test-token",
		EVIDENCE_BUCKET: {
			put: async () => undefined,
			get: async () => null,
		},
		...overrides,
	};
}

test("stores webm and mp4 uploads with their browser video MIME types", async () => {
	for (const [extension, contentType] of [
		["webm", "video/webm"],
		["mp4", "video/mp4"],
	]) {
		let storedContentType = "";
		const response = await worker.fetch(
			new Request(`https://evidence.example/workspaces/pr-1027/demo.${extension}`, {
				method: "PUT",
				headers: {
					Authorization: "Bearer test-token",
					"Content-Length": "3",
				},
				body: new Uint8Array([1, 2, 3]),
			}),
			env({
				EVIDENCE_BUCKET: {
					put: async (_key, _body, options) => {
						storedContentType = options?.httpMetadata?.contentType ?? "";
					},
				},
			}),
		);

		assert.equal(response.status, 201);
		assert.equal(storedContentType, contentType);
	}
});

test("rejects uploads declared over the cap before touching R2", async () => {
	let putCalled = false;
	const response = await worker.fetch(
		new Request("https://evidence.example/workspaces/pr-1027/too-large.webm", {
			method: "PUT",
			headers: {
				Authorization: "Bearer test-token",
				"Content-Length": String(MAX_UPLOAD_BYTES + 1),
			},
			body: new Uint8Array([1]),
		}),
		env({
			EVIDENCE_BUCKET: {
				put: async () => {
					putCalled = true;
				},
			},
		}),
	);

	assert.equal(response.status, 413);
	assert.equal(putCalled, false);
	assert.equal(await response.text(), "upload exceeds the 50 MiB limit");
});

test("requires a valid fixed upload length before reading or storing", async () => {
	for (const [contentLength, expectedStatus] of [
		[null, 411],
		["not-a-number", 400],
		["-1", 400],
	]) {
		let putCalled = false;
		const headers = { Authorization: "Bearer test-token" };
		if (contentLength !== null) headers["Content-Length"] = contentLength;
		const response = await worker.fetch(
			new Request("https://evidence.example/workspaces/pr-1027/video.webm", {
				method: "PUT",
				headers,
				body: new Uint8Array([1]),
			}),
			env({
				EVIDENCE_BUCKET: {
					put: async () => {
						putCalled = true;
					},
				},
			}),
		);
		assert.equal(response.status, expectedStatus);
		assert.equal(putCalled, false);
	}
});

test("streams an exact-limit upload to R2 without buffering it", async () => {
	const request = new Request(
		"https://evidence.example/workspaces/pr-1027/exact.webm",
		{
			method: "PUT",
			headers: {
				Authorization: "Bearer test-token",
				"Content-Length": String(MAX_UPLOAD_BYTES),
			},
			// The Worker trusts Cloudflare HTTP framing for the declared length;
			// this small synthetic body lets the test observe allocation shape.
			body: new Uint8Array([1]),
		},
	);
	const originalBody = request.body;
	let storedBody;
	const response = await worker.fetch(
		request,
		env({
			EVIDENCE_BUCKET: {
				put: async (_key, body) => {
					storedBody = body;
				},
			},
		}),
	);

	assert.equal(response.status, 201);
	assert.equal(storedBody, originalBody);
});
