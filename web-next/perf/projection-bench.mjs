/*
 * In-process benchmark for the session-events → UIMessage projection
 * (perf/contract.json `projection_200`). Unlike the browser scenarios in
 * run.mjs, this measures a pure Node function, so run.mjs invokes it under tsx
 * (which resolves the TypeScript import) and reads the JSON samples it prints.
 *
 * Methodology: build a deterministic ~200-event log (20 interleaved
 * user+assistant turns, each with status/text/tool events), warm up once to
 * settle JIT, then time `projectSessionEvents` over N runs. Emits
 * `{ "samples": [ms, …] }` on stdout.
 */
import { projectSessionEvents } from "../src/lib/transcript/project-events.ts";

const RUNS = Number(process.argv[2] ?? 5);

/** Ten events per turn → 20 turns = 200 events. */
function buildTurn(turn) {
	const s = turn * 10; // seq base for this turn
	const a = (seq, type, content, metadata) => ({
		seq,
		role: "assistant",
		chunk: { type, content, ...(metadata ? { metadata } : {}) },
	});
	return [
		{ seq: s + 1, role: "user", chunk: { type: "text", content: `Request ${turn}` } },
		a(s + 2, "status", "Working"),
		a(s + 3, "text", "Let me investigate the issue. "),
		a(s + 4, "tool_use", "Read", {
			toolUseId: `t-${turn}-1`,
			toolName: "Read",
			input: { file_path: `src/mod-${turn}.ts` },
		}),
		a(s + 5, "tool_result", "const x = load();", { toolUseId: `t-${turn}-1` }),
		a(s + 6, "text", "Found the cause. Applying the fix. "),
		a(s + 7, "tool_use", "Bash", {
			toolUseId: `t-${turn}-2`,
			toolName: "Bash",
			input: { command: "pnpm test" },
		}),
		a(s + 8, "tool_result", "Tests: 12 passed", { toolUseId: `t-${turn}-2` }),
		a(s + 9, "text", "All tests pass."),
		a(s + 10, "done", ""),
	];
}

function buildLog(turns) {
	const events = [];
	for (let t = 0; t < turns; t++) events.push(...buildTurn(t));
	return events;
}

async function main() {
	const events = buildLog(20);
	if (events.length !== 200) {
		throw new Error(`expected 200 events, built ${events.length}`);
	}

	// Warm up (JIT + module init) so the first timed run isn't an outlier.
	await projectSessionEvents("perf-warmup", events);

	const samples = [];
	for (let i = 0; i < RUNS; i++) {
		const start = performance.now();
		const messages = await projectSessionEvents("perf", events);
		samples.push(performance.now() - start);
		// Guard the workload actually produced the full transcript.
		if (messages.length !== 40) {
			throw new Error(`expected 40 messages, got ${messages.length}`);
		}
	}

	process.stdout.write(`${JSON.stringify({ samples })}\n`);
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
