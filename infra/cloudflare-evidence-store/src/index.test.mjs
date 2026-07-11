import assert from "node:assert/strict";
import test from "node:test";
import worker, { MAX_UPLOAD_BYTES, readBodyWithinLimit } from "./index.ts";

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
				headers: { Authorization: "Bearer test-token" },
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

test("bounds the actual stream when Content-Length is absent or undersized", async () => {
	const exact = await readBodyWithinLimit(
		new Response(new Uint8Array([1, 2, 3])).body,
		3,
	);
	assert.deepEqual([...new Uint8Array(exact)], [1, 2, 3]);

	const oversized = await readBodyWithinLimit(
		new Response(new Uint8Array([1, 2, 3, 4])).body,
		3,
	);
	assert.equal(oversized, null);
});
