import assert from "node:assert/strict";
import test from "node:test";
import worker from "./index.ts";
import { MAX_UPLOAD_BYTES, mintKey, mintKeySegment } from "./evidence.ts";

function env(overrides = {}) {
	return {
		EVIDENCE_UPLOAD_TOKEN: "test-token",
		EVIDENCE_BUCKET: {
			put: async () => undefined,
			get: async () => null,
			delete: async () => undefined,
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

test("mints an unguessable key segment above the filename", async () => {
	let storedKey = "";
	const response = await worker.fetch(
		new Request("https://evidence.example/workspaces/pr-1027/shot.png", {
			method: "PUT",
			headers: { Authorization: "Bearer test-token", "Content-Length": "1" },
			body: new Uint8Array([1]),
		}),
		env({
			EVIDENCE_BUCKET: {
				put: async (key) => {
					storedKey = key;
				},
			},
		}),
	);

	assert.equal(response.status, 201);
	const segments = storedKey.split("/");
	assert.equal(segments.length, 4);
	assert.deepEqual(segments.slice(0, 2), ["workspaces", "pr-1027"]);
	assert.equal(segments[3], "shot.png");
	assert.match(segments[2], /^[A-Za-z0-9_-]{22}$/);

	// The requested path is no longer a valid URL, so the caller has to read the
	// minted one back out of the response.
	const body = await response.json();
	assert.equal(body.key, storedKey);
	assert.equal(body.url, `https://evidence.example/${storedKey}`);
});

test("gives two uploads of the same path different keys", async () => {
	const keys = [];
	for (let i = 0; i < 2; i++) {
		await worker.fetch(
			new Request("https://evidence.example/workspaces/pr-1027/shot.png", {
				method: "PUT",
				headers: { Authorization: "Bearer test-token", "Content-Length": "1" },
				body: new Uint8Array([1]),
			}),
			env({
				EVIDENCE_BUCKET: {
					put: async (key) => {
						keys.push(key);
					},
				},
			}),
		);
	}
	assert.equal(keys.length, 2);
	assert.notEqual(keys[0], keys[1]);
});

test("mintKeySegment draws fresh entropy every call", () => {
	const seen = new Set();
	for (let i = 0; i < 100; i++) seen.add(mintKeySegment());
	assert.equal(seen.size, 100);
});

test("mintKey handles a bare filename with no directory", () => {
	assert.equal(mintKey("shot.png", "SEG"), "SEG/shot.png");
	assert.equal(mintKey("a/b/shot.png", "SEG"), "a/b/SEG/shot.png");
});

test("serves legacy keys stored before the minted segment existed", async () => {
	const legacyKey = "workspaces/pr-142/20260318-120000-sidebar.png";
	let requestedKey = "";
	const response = await worker.fetch(
		new Request(`https://evidence.example/${legacyKey}`),
		env({
			EVIDENCE_BUCKET: {
				get: async (key) => {
					requestedKey = key;
					return { body: "bytes", httpMetadata: { contentType: "image/png" } };
				},
			},
		}),
	);

	assert.equal(response.status, 200);
	assert.equal(requestedKey, legacyKey);
});

test("withdraws an upload when the request carries the upload token", async () => {
	const key = "workspaces/pr-1027/abcdefghijklmnopqrstuv/shot.png";
	let deletedKey = "";
	const response = await worker.fetch(
		new Request(`https://evidence.example/${key}`, {
			method: "DELETE",
			headers: { Authorization: "Bearer test-token" },
		}),
		env({
			EVIDENCE_BUCKET: {
				delete: async (k) => {
					deletedKey = k;
				},
			},
		}),
	);

	assert.equal(response.status, 204);
	assert.equal(deletedKey, key);
});

test("refuses an unauthenticated or mis-tokened DELETE without touching R2", async () => {
	for (const headers of [{}, { Authorization: "Bearer wrong-token" }]) {
		let deleteCalled = false;
		const response = await worker.fetch(
			new Request("https://evidence.example/workspaces/pr-1027/seg/shot.png", {
				method: "DELETE",
				headers,
			}),
			env({
				EVIDENCE_BUCKET: {
					delete: async () => {
						deleteCalled = true;
					},
				},
			}),
		);

		assert.equal(response.status, 401);
		assert.equal(deleteCalled, false);
	}
});

test("keeps DELETE out of the CORS method allowlist", async () => {
	const response = await worker.fetch(
		new Request("https://evidence.example/anything", { method: "OPTIONS" }),
		env(),
	);
	assert.equal(
		response.headers.get("Access-Control-Allow-Methods"),
		"GET, OPTIONS",
	);
});
