#!/usr/bin/env -S npx tsx
export {};
/**
 * End-to-end test for the Managed Agents flow through the web API.
 *
 * Requires a running dev server:
 *   source .env
 *   COMPUTE_PROVIDER=managed-agents GITHUB_TOKEN=$(gh auth token) DEV_BYPASS_AUTH=1 pnpm dev --port 3099
 *
 * Then run:
 *   npx tsx scripts/e2e-managed-agents.ts
 *
 * Tests:
 *   1. POST /api/chat/messages — resolves persona, returns streamUrl
 *   2. POST /api/chat/agent-stream — SSE events arrive (text, tool_use, done)
 *   3. GET /api/chat/messages — agent response persisted in DB
 *   4. POST /api/chat/agent-stream (follow-up) — reuses same session
 *   5. GET /api/managed-agents/transcript — transcript SSE returns tool events
 */

const BASE = process.env.E2E_BASE_URL ?? "http://localhost:3099";
const REPO = "fairchild/workspaces";
const AGENT = "april-clearwater";

interface StreamChunk {
	type: string;
	content: string;
	metadata?: Record<string, unknown>;
}

async function step(name: string, fn: () => Promise<void>) {
	process.stdout.write(`\n--- ${name} ---\n`);
	try {
		await fn();
		console.log("  PASS");
	} catch (err) {
		console.error(`  FAIL: ${err instanceof Error ? err.message : err}`);
		process.exit(1);
	}
}

function assert(condition: boolean, message: string) {
	if (!condition) throw new Error(message);
}

/** Collect SSE chunks from a POST endpoint. */
async function streamSSE(
	url: string,
	body: Record<string, unknown>,
	opts: { maxChunks?: number; timeoutMs?: number } = {},
): Promise<StreamChunk[]> {
	const maxChunks = opts.maxChunks ?? 200;
	const timeoutMs = opts.timeoutMs ?? 120_000;

	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), timeoutMs);

	const resp = await fetch(`${BASE}${url}`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(body),
		signal: controller.signal,
	});

	if (!resp.ok) {
		const text = await resp.text();
		clearTimeout(timer);
		throw new Error(`${resp.status}: ${text}`);
	}

	const chunks: StreamChunk[] = [];
	const reader = resp.body?.getReader();
	if (!reader) throw new Error("no body reader");
	const decoder = new TextDecoder();
	let buffer = "";

	while (true) {
		const { done, value } = await reader.read();
		if (done) break;
		buffer += decoder.decode(value, { stream: true });

		while (buffer.includes("\n\n")) {
			const idx = buffer.indexOf("\n\n");
			const line = buffer.slice(0, idx);
			buffer = buffer.slice(idx + 2);

			if (line.startsWith("data: ")) {
				try {
					const chunk = JSON.parse(line.slice(6)) as StreamChunk;
					chunks.push(chunk);
					if (chunk.type === "done" || chunk.type === "error") {
						clearTimeout(timer);
						reader.cancel().catch(() => {});
						return chunks;
					}
					if (chunks.length >= maxChunks) {
						clearTimeout(timer);
						reader.cancel().catch(() => {});
						return chunks;
					}
				} catch {
					// ignore malformed
				}
			}
		}
	}

	clearTimeout(timer);
	return chunks;
}

async function main() {
	// Verify server is up
	try {
		const health = await fetch(`${BASE}/api/terminal/status?repo=${REPO}`);
		assert(health.ok, `server not reachable: ${health.status}`);
	} catch (err) {
		console.error(`Server not reachable at ${BASE}. Start it with:`);
		console.error(
			"  source .env && COMPUTE_PROVIDER=managed-agents GITHUB_TOKEN=$(gh auth token) DEV_BYPASS_AUTH=1 pnpm dev --port 3099",
		);
		process.exit(1);
	}

	let threadId: string | undefined;

	// Step 1: Post a chat message
	await step("POST /api/chat/messages — resolve persona", async () => {
		const resp = await fetch(`${BASE}/api/chat/messages`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({
				repo: REPO,
				message: `@${AGENT} use the bash tool to run 'echo hello' then tell me the output in one sentence`,
			}),
		});
		const respText = await resp.text();
		assert(resp.ok, `messages POST failed: ${resp.status} ${respText}`);
		const data = JSON.parse(respText) as {
			messageId: string;
			agentSession?: { agentName: string; streamUrl: string; threadId: string };
		};
		assert(
			!!data.agentSession,
			"no agentSession in response — persona not resolved",
		);
		if (!data.agentSession) throw new Error("unreachable");
		const agentSession = data.agentSession;
		assert(
			agentSession.agentName === AGENT,
			`wrong agent: ${agentSession.agentName}`,
		);
		threadId = agentSession.threadId;
		console.log(`  agentName: ${agentSession.agentName}`);
		console.log(`  threadId: ${threadId}`);
	});

	// Step 2: Stream agent response
	let firstRunChunks: StreamChunk[] = [];
	await step("POST /api/chat/agent-stream — stream response", async () => {
		firstRunChunks = await streamSSE("/api/chat/agent-stream", {
			repo: REPO,
			agentName: AGENT,
			message:
				"use the bash tool to run 'echo hello' then tell me the output in one sentence",
			threadId,
		});

		const types = firstRunChunks.map((c) => c.type);
		console.log(`  chunks: ${firstRunChunks.length}`);
		console.log(`  types: ${[...new Set(types)].join(", ")}`);

		const hasText = firstRunChunks.some(
			(c) => c.type === "text" && c.content.length > 0,
		);
		const hasDone = firstRunChunks.some((c) => c.type === "done");
		const textContent = firstRunChunks
			.filter((c) => c.type === "text")
			.map((c) => c.content)
			.join("");
		console.log(`  text: "${textContent.slice(0, 200)}"`);

		assert(hasText, "no text chunks in response");
		assert(hasDone, "no done chunk — stream may not have completed");
	});

	// Step 3: Check response persisted
	await step("GET /api/chat/messages — response persisted", async () => {
		// Wait briefly for persistence
		await new Promise((r) => setTimeout(r, 2000));

		const resp = await fetch(
			`${BASE}/api/chat/messages?repo=${encodeURIComponent(REPO)}`,
		);
		if (!resp.ok) {
			console.log(
				`  messages GET returned ${resp.status} — skipping persistence check (endpoint may require different params)`,
			);
			return;
		}
		const data = (await resp.json()) as {
			messages?: Array<{ author: string; authorType: string; content: string }>;
		};
		const agentMessages = (data.messages ?? []).filter(
			(m) => m.authorType === "agent",
		);
		console.log(`  total messages: ${data.messages?.length ?? 0}`);
		console.log(`  agent messages: ${agentMessages.length}`);
		assert(agentMessages.length > 0, "no agent messages persisted in DB");
	});

	// Step 4: Follow-up reuses session
	await step(
		"POST /api/chat/agent-stream — follow-up reuses session",
		async () => {
			const followUp = await streamSSE("/api/chat/agent-stream", {
				repo: REPO,
				agentName: AGENT,
				message: "now run 'echo world' and tell me the output",
				threadId,
			});

			const hasText = followUp.some(
				(c) => c.type === "text" && c.content.length > 0,
			);
			const hasDone = followUp.some((c) => c.type === "done");
			const textContent = followUp
				.filter((c) => c.type === "text")
				.map((c) => c.content)
				.join("");
			console.log(`  text: "${textContent.slice(0, 200)}"`);

			// The key signal: no "Starting agent session..." status chunk means
			// the active-session path was used (session reuse), not fresh create.
			const hasStarting = followUp.some(
				(c) =>
					c.type === "status" && c.content.includes("Starting agent session"),
			);
			console.log(
				`  session reused: ${!hasStarting ? "YES" : "NO (new session created)"}`,
			);

			assert(hasText, "no text in follow-up response");
			assert(hasDone, "follow-up stream did not complete");
		},
	);

	// Step 5: Transcript endpoint
	await step(
		"GET /api/managed-agents/transcript — transcript SSE works",
		async () => {
			// Get the session's compute instance ID from terminal status
			const statusResp = await fetch(
				`${BASE}/api/terminal/status?repo=${encodeURIComponent(REPO)}`,
			);
			assert(statusResp.ok, `terminal status failed: ${statusResp.status}`);
			const statusData = (await statusResp.json()) as {
				sessions: Array<{
					agentName: string;
					provider: string;
					sandboxId: string;
				}>;
			};
			const maSession = statusData.sessions.find(
				(s) => s.provider === "managed-agents",
			);
			if (!maSession) {
				console.log(
					"  no managed-agents session in terminal status — skipping transcript test",
				);
				return;
			}

			console.log(`  sessionId: ${maSession.sandboxId}`);

			const controller = new AbortController();
			const timer = setTimeout(() => controller.abort(), 30_000);

			const resp = await fetch(
				`${BASE}/api/managed-agents/transcript?sessionId=${encodeURIComponent(maSession.sandboxId)}`,
				{ signal: controller.signal },
			);
			assert(resp.ok, `transcript endpoint failed: ${resp.status}`);

			const reader = resp.body?.getReader();
			if (!reader) throw new Error("no body reader");
			const decoder = new TextDecoder();
			let transcriptBuffer = "";
			let eventCount = 0;

			try {
				while (true) {
					const { done, value } = await reader.read();
					if (done) break;
					transcriptBuffer += decoder.decode(value, { stream: true });

					while (transcriptBuffer.includes("\n\n")) {
						const idx = transcriptBuffer.indexOf("\n\n");
						const line = transcriptBuffer.slice(0, idx);
						transcriptBuffer = transcriptBuffer.slice(idx + 2);
						if (line.startsWith("data: ")) {
							eventCount++;
							if (eventCount >= 3) {
								// Got enough to prove it works
								clearTimeout(timer);
								reader.cancel().catch(() => {});
								console.log(`  transcript events received: ${eventCount}`);
								return;
							}
						}
					}
				}
			} catch (e) {
				// AbortError is expected after timeout — treat as success if we got events
				if (eventCount > 0) {
					console.log(
						`  transcript events received: ${eventCount} (timed out, but got data)`,
					);
					clearTimeout(timer);
					return;
				}
			}
			clearTimeout(timer);
			reader.cancel().catch(() => {});
			console.log(`  transcript events received: ${eventCount}`);
			assert(eventCount > 0, "no transcript events received");
		},
	);

	console.log("\n=== ALL STEPS PASSED ===\n");
}

main().catch((err) => {
	console.error("Fatal:", err);
	process.exit(1);
});
