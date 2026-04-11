#!/usr/bin/env -S npx tsx
/**
 * Integration test for the ManagedAgentsProvider — exercises the full
 * create-agent → create-environment → create-session → send-message →
 * stream-events → archive flow against the real Anthropic API.
 *
 * Usage:
 *   source .env
 *   COMPUTE_PROVIDER=managed-agents npx tsx scripts/test-managed-agents.ts
 *
 * Requires ANTHROPIC_API_KEY in the environment.
 */
import { ManagedAgentsProvider } from "../src/lib/agent-runtime/managed-agents";
import type { StreamChunk } from "../src/lib/agent-runtime/types";

async function main() {
	const apiKey = process.env.ANTHROPIC_API_KEY;
	if (!apiKey) {
		console.error("ANTHROPIC_API_KEY is not set");
		process.exit(1);
	}

	// Use an in-memory sqlite DB for the cache (don't touch real dev data)
	process.env.TURSO_DATABASE_URL = "file::memory:";

	const provider = new ManagedAgentsProvider();

	console.log("--- checkAvailability ---");
	const avail = await provider.checkAvailability();
	console.log("available:", avail.available, avail.reason ?? "");
	if (!avail.available) {
		console.error("Provider not available, aborting.");
		process.exit(1);
	}

	console.log("\n--- createSandbox ---");
	const ghToken = process.env.GITHUB_TOKEN ?? "";
	const result = await provider.createSandbox({
		sessionId: `test-${Date.now()}`,
		repo: "fairchild/workspaces",
		cloneUrl: "https://github.com/fairchild/workspaces.git",
		readOnly: true,
		systemPrompt:
			"You are a helpful coding agent. Keep your response brief (under 100 words).",
		message:
			"List the top-level files in /workspace/repo and tell me in one sentence what this project is about.",
		tools: "conversational",
		envVars: { GITHUB_TOKEN: ghToken },
	});
	console.log("instanceId:", result.instanceId);
	console.log("status:", result.status);

	console.log("\n--- streamOutput ---");
	const chunks: StreamChunk[] = [];
	let textContent = "";
	for await (const chunk of provider.streamOutput(result.instanceId)) {
		chunks.push(chunk);
		switch (chunk.type) {
			case "text":
				process.stdout.write(chunk.content);
				textContent += chunk.content;
				break;
			case "tool_use":
				console.log(`\n[tool: ${chunk.content}]`);
				break;
			case "tool_result":
				console.log(`  → ${chunk.content.slice(0, 200)}`);
				break;
			case "status":
				console.log(`[status: ${chunk.content}]`);
				break;
			case "done":
				console.log("\n[done]");
				break;
			case "error":
				console.error(`\n[ERROR: ${chunk.content}]`);
				break;
		}
	}

	console.log("\n--- summary ---");
	console.log("total chunks:", chunks.length);
	console.log(
		"chunk types:",
		Object.entries(
			chunks.reduce(
				(acc, c) => {
					acc[c.type] = (acc[c.type] || 0) + 1;
					return acc;
				},
				{} as Record<string, number>,
			),
		)
			.map(([k, v]) => `${k}:${v}`)
			.join(", "),
	);
	console.log("text length:", textContent.length);

	const hasText = chunks.some((c) => c.type === "text" && c.content.length > 0);
	const hasDone = chunks.some((c) => c.type === "done");
	const hasToolUse = chunks.some((c) => c.type === "tool_use");

	console.log("\n--- assertions ---");
	console.log("has text:", hasText ? "PASS" : "FAIL");
	console.log("has done:", hasDone ? "PASS" : "FAIL");
	console.log("has tool_use:", hasToolUse ? "PASS" : "FAIL");

	console.log("\n--- sendMessage (follow-up) ---");
	await provider.sendMessage(
		result.instanceId,
		"What language is this project primarily written in?",
	);
	let followUpText = "";
	for await (const chunk of provider.streamOutput(result.instanceId)) {
		if (chunk.type === "text") {
			process.stdout.write(chunk.content);
			followUpText += chunk.content;
		}
		if (chunk.type === "done") {
			console.log("\n[done]");
			break;
		}
		if (chunk.type === "error") {
			console.error(`\n[ERROR: ${chunk.content}]`);
			break;
		}
	}
	console.log("follow-up text length:", followUpText.length);
	console.log("follow-up has text:", followUpText.length > 0 ? "PASS" : "FAIL");

	console.log("\n--- destroySandbox (archive) ---");
	await provider.destroySandbox(result.instanceId);
	console.log("archived:", result.instanceId);

	const allPass = hasText && hasDone && hasToolUse && followUpText.length > 0;
	console.log("\n=== RESULT:", allPass ? "ALL PASS" : "SOME FAILED", "===");
	process.exit(allPass ? 0 : 1);
}

main().catch((err) => {
	console.error("Fatal:", err);
	process.exit(1);
});
