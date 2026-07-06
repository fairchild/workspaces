/*
 * Local driver for the real "vercel" compute provider: runs one turn end-to-end
 * (mint token → sandbox → Claude Code → clone/commit/push/PR) and prints the
 * StreamChunks as they arrive. Not part of the app — a manual smoke harness.
 *
 *   node --env-file=.env.local --import tsx scripts/drive-turn.ts "your message"
 */
import { vercelProvider } from "../src/lib/agent-runtime/vercel-provider";

const userMessage = process.argv[2] ?? "Open a smoke-test PR to prove the runtime works.";

const started = Date.now();
const t = () => `${((Date.now() - started) / 1000).toFixed(1)}s`;

async function main() {
	for await (const chunk of vercelProvider.runTurn({
		sessionId: "local-drive",
		userMessage,
	})) {
		switch (chunk.type) {
		case "status":
			console.log(`[${t()}] ● status: ${chunk.content}`);
			break;
		case "reasoning":
			process.stdout.write(chunk.content);
			break;
		case "text":
			process.stdout.write(chunk.content);
			break;
		case "tool_use":
			console.log(
				`\n[${t()}] → tool ${chunk.content} ${JSON.stringify(chunk.metadata?.input ?? {}).slice(0, 200)}`,
			);
			break;
		case "tool_result":
			console.log(
				`[${t()}] ← result${chunk.metadata?.isError ? " (error)" : ""}: ${chunk.content.slice(0, 300)}`,
			);
			break;
		case "error":
			console.log(`\n[${t()}] ✗ error: ${chunk.content}`);
			break;
		case "done":
			console.log(
				`\n[${t()}] ✓ done — ${JSON.stringify(chunk.metadata ?? {})}`,
			);
			break;
		}
	}
}

main().catch((err) => {
	console.error("\n[driver] fatal:", err);
	process.exit(1);
});
