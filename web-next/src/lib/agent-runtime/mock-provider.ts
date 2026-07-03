/*
 * The mock compute provider: a deterministic scripted coding turn (status →
 * prose → Read/Edit/Bash with results, a landed diff, a test run → done with
 * usage figures) that exercises the whole Folio apparatus without a sandbox.
 * Paced with small delays so streaming behavior is observable and measurable.
 */
import type { ComputeProvider, TurnRequest } from "./provider";
import type { StreamChunk } from "./stream-chunk";

type Sleep = (ms: number) => Promise<void>;

const defaultSleep: Sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const EDITED_FILE = "src/lib/session.ts";

const EDIT_DIFF = {
	file: EDITED_FILE,
	additions: 3,
	deletions: 1,
	note: "edit landed · just now",
	lines: [
		{ kind: "context", text: "  export function resumeSession(id: string) {" },
		{ kind: "del", text: "-   return store.get(id); // BUG: no null check" },
		{ kind: "add", text: "+   const session = store.get(id);" },
		{ kind: "add", text: "+   if (!session) throw new SessionNotFoundError(id);" },
		{ kind: "add", text: "+   return session;" },
		{ kind: "context", text: "  }" },
	],
} as const;

const TEST_RUN_OUTPUT = [
	"✓ session.test.ts (4 tests) 212ms",
	"",
	"Test Files  1 passed (1)",
	"     Tests  4 passed (4)",
].join("\n");

/**
 * The scripted turn. `sleep` is injectable so tests can consume the whole
 * script without waiting out the streaming pace.
 */
export async function* mockCodingTurn(
	userMessage: string,
	sleep: Sleep = defaultSleep,
): AsyncGenerator<StreamChunk> {
	const startedAt = Date.now();
	let proseChars = 0;

	async function* prose(text: string): AsyncGenerator<StreamChunk> {
		proseChars += text.length;
		for (const word of text.split(" ")) {
			yield { type: "text", content: `${word} ` };
			await sleep(30);
		}
	}

	yield { type: "status", content: "Starting sandbox" };
	await sleep(300);
	yield { type: "status", content: "Cloning repo" };
	await sleep(300);

	yield* prose(
		`You asked: "${userMessage}". Let me look at the failing test first.`,
	);

	yield { type: "status", content: `Reading \`${EDITED_FILE}\`` };
	yield {
		type: "tool_use",
		content: "Read",
		metadata: {
			toolUseId: "tool-1",
			toolName: "Read",
			input: { file_path: EDITED_FILE },
		},
	};
	await sleep(400);
	yield {
		type: "tool_result",
		content:
			"export function resumeSession(id: string) {\n\treturn store.get(id); // BUG: no null check\n}",
		metadata: { toolUseId: "tool-1" },
	};

	yield* prose(
		"Found it — `resumeSession` never handles a missing id. I'll add the guard and re-run the tests.",
	);

	yield { type: "status", content: `Editing \`${EDITED_FILE}\`` };
	yield {
		type: "tool_use",
		content: "Edit",
		metadata: {
			toolUseId: "tool-2",
			toolName: "Edit",
			input: {
				file_path: EDITED_FILE,
				old_string: "return store.get(id);",
				new_string:
					"const session = store.get(id);\nif (!session) throw new SessionNotFoundError(id);\nreturn session;",
			},
		},
	};
	await sleep(400);
	yield {
		type: "tool_result",
		content: "Edit applied.",
		metadata: { toolUseId: "tool-2", diff: EDIT_DIFF },
	};

	yield { type: "status", content: "Running `pnpm test session`" };
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
		content: TEST_RUN_OUTPUT,
		metadata: { toolUseId: "tool-3" },
	};

	yield { type: "status", content: "Writing up the fix" };
	yield* prose(
		"All four tests pass. The fix adds a `SessionNotFoundError` guard instead of returning undefined.",
	);

	yield {
		type: "done",
		content: "",
		metadata: {
			durationMs: Date.now() - startedAt,
			// A plausible usage figure for the receipt: ~4 chars per token.
			tokenCount: Math.ceil(proseChars / 4),
		},
	};
}

export const mockProvider: ComputeProvider = {
	id: "mock",
	runTurn: (request: TurnRequest) => mockCodingTurn(request.userMessage),
};
