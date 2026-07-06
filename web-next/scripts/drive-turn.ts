/*
 * Local driver for the real "vercel" compute provider. Runs TWO turns against
 * one session id, threading the resume handle the first turn parks into the
 * second — so it exercises the whole path end-to-end: real message-driven turn,
 * detach/park, reconnect, and conversational continuity. Prints the StreamChunks
 * as they arrive. Not part of the app — a manual smoke harness.
 *
 *   HARNESS_DEBUG=1 node --env-file=.env.local --import tsx scripts/drive-turn.ts
 *   node --env-file=.env.local --import tsx scripts/drive-turn.ts "turn 1" "turn 2"
 */
import { vercelProvider } from "../src/lib/agent-runtime/vercel-provider";
import type { SessionResumeHandle } from "../src/lib/agent-runtime/provider";

const turn1 =
	process.argv[2] ??
	"In web-next/, create or update a file RUNTIME-NOTE.md with a single line: 'harness runtime online'. Then show me `git -C /vercel/sandbox/workspace diff`. Do not open a PR.";
const turn2 =
	process.argv[3] ??
	"Which file did you just edit? Append a second line to it saying 'resumed turn ok', then show the diff again. Do not open a PR.";

// Unique per run so a leftover parked sandbox from a prior run can't collide.
const sessionId = `local-drive-${Date.now().toString(36)}`;
console.log(
	`sandbox: ai-sdk-harness-session-${sessionId} (clean up with scripts/sandbox-cleanup.ts if it lingers)`,
);
const started = Date.now();
const t = () => `${((Date.now() - started) / 1000).toFixed(1)}s`;

async function runTurn(
	label: string,
	userMessage: string,
	resume: SessionResumeHandle | null,
): Promise<SessionResumeHandle | null> {
	console.log(`\n=== ${label} ===`);
	let firstToken: number | null = null;
	let parked: SessionResumeHandle | null = null;
	for await (const chunk of vercelProvider.runTurn({
		sessionId,
		userMessage,
		resume,
	})) {
		switch (chunk.type) {
			case "status":
				console.log(`[${t()}] ● ${chunk.content}`);
				break;
			case "reasoning":
			case "text":
				if (firstToken === null) {
					firstToken = Date.now() - started;
					console.log(`[${t()}] ⏱ first token (TTFT this turn)`);
				}
				process.stdout.write(chunk.content);
				break;
			case "tool_use":
				console.log(
					`\n[${t()}] → ${chunk.content} ${JSON.stringify(chunk.metadata?.input ?? {}).slice(0, 200)}`,
				);
				break;
			case "tool_result":
				console.log(
					`[${t()}] ← ${chunk.metadata?.isError ? "(error) " : ""}${chunk.content.slice(0, 240)}`,
				);
				break;
			case "error":
				console.log(`\n[${t()}] ✗ error: ${chunk.content}`);
				break;
			case "done": {
				const resumeOut = chunk.metadata?.resume as SessionResumeHandle | null | undefined;
				parked = resumeOut ?? null;
				console.log(
					`\n[${t()}] ✓ done — durationMs=${chunk.metadata?.durationMs} tokens=${chunk.metadata?.tokenCount} parked=${parked ? "yes" : "no"}`,
				);
				break;
			}
		}
	}
	return parked;
}

async function main() {
	const parked = await runTurn("TURN 1 (fresh)", turn1, null);
	if (!parked) {
		console.log("\n[driver] turn 1 did not park a resume handle — skipping resume turn.");
		return;
	}
	await runTurn("TURN 2 (resumed)", turn2, parked);
}

main().catch((err) => {
	console.error("\n[driver] fatal:", err);
	process.exit(1);
});
