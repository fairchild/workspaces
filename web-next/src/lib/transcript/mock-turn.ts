/*
 * Deterministic mock agent turn: emits the StreamChunk sequence a real
 * coding session produces (status → text → tool calls → results → text),
 * with small delays so streaming behavior is observable in the spike.
 */
import type { StreamChunk } from "../agent-runtime/stream-chunk";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function* mockCodingTurn(
	userMessage: string,
): AsyncGenerator<StreamChunk> {
	yield { type: "status", content: "Starting sandbox" };
	await sleep(300);
	yield { type: "status", content: "Cloning repo" };
	await sleep(300);

	for (const word of `You asked: "${userMessage}". Let me look at the failing test first.`.split(
		" ",
	)) {
		yield { type: "text", content: `${word} ` };
		await sleep(30);
	}

	yield {
		type: "tool_use",
		content: "Read",
		metadata: {
			toolUseId: "tool-1",
			toolName: "Read",
			input: { file_path: "src/lib/session.ts" },
		},
	};
	await sleep(400);
	yield {
		type: "tool_result",
		content:
			"export function resumeSession(id: string) {\n\treturn store.get(id); // BUG: no null check\n}",
		metadata: { toolUseId: "tool-1" },
	};

	for (const word of "Found it — `resumeSession` never handles a missing id. I'll add the guard and re-run the tests.".split(
		" ",
	)) {
		yield { type: "text", content: `${word} ` };
		await sleep(30);
	}

	yield {
		type: "tool_use",
		content: "Edit",
		metadata: {
			toolUseId: "tool-2",
			toolName: "Edit",
			input: {
				file_path: "src/lib/session.ts",
				old_string: "return store.get(id);",
				new_string:
					'const session = store.get(id);\nif (!session) throw new SessionNotFoundError(id);\nreturn session;',
			},
		},
	};
	await sleep(400);
	yield {
		type: "tool_result",
		content: "Edit applied.",
		metadata: { toolUseId: "tool-2" },
	};

	yield {
		type: "tool_use",
		content: "Bash",
		metadata: {
			toolUseId: "tool-3",
			toolName: "Bash",
			input: { command: "pnpm test session" },
		},
	};
	await sleep(700);
	yield {
		type: "tool_result",
		content: "✓ session.test.ts (4 tests) 212ms\n\nTest Files  1 passed (1)\n     Tests  4 passed (4)",
		metadata: { toolUseId: "tool-3" },
	};

	for (const word of "All four tests pass. The fix adds a `SessionNotFoundError` guard instead of returning undefined.".split(
		" ",
	)) {
		yield { type: "text", content: `${word} ` };
		await sleep(30);
	}

	yield { type: "done", content: "" };
}
