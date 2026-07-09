/*
 * The mock compute provider: a deterministic scripted coding turn (status →
 * reasoning → prose → a failing test → Read/Edit → a passing test, a landed
 * diff → done with usage figures) that exercises the whole Folio apparatus —
 * including the thinking block and the error tool path — without a sandbox.
 * Paced with small delays so streaming behavior is observable and measurable.
 * The requested model and repo are recorded (not used — there's no real model
 * call or clone here) on the terminal `done` chunk, so routing is
 * unit-testable against this provider without a sandbox.
 *
 * A user message containing `MOCK_APPROVAL_TRIGGER` runs the approval scenario
 * (#982): the mock emits a real approval_request, waits on the turn's broker
 * callback, emits approval_resolved, then either continues (allow) or stops
 * quietly (deny/timeout/abort). That keeps the end-to-end surface testable
 * without credentials or host filesystem access.
 *
 * A user message containing `MOCK_TURN_ERROR_TRIGGER` (#808) throws instead of
 * running the script — a deterministic, hermetic way to exercise a whole-turn
 * failure (turn-ingest.ts's catch appends the `error` + aborted `done` a real
 * provider fault or dead sandbox would) without depending on timing or a real
 * provider outage. #753 adds one trigger per first-class error surface —
 * provisioning failure, sandbox died mid-turn, stream error — each failing at
 * the point and through the mechanism its real counterpart would (see the
 * trigger constants below). Test-only by convention: nothing in the product
 * surface sends this text on purpose.
 *
 * `mockCodingTurn` itself always fails when the trigger is present — that's
 * what makes it hermetically unit-testable. `mockProvider.runTurn` (the seam
 * sessions actually call) spends the trigger once per session: the first turn
 * against a session whose text carries it fails, and a later turn against
 * that same session — e.g. a UI Retry re-sending the identical failed text —
 * runs the normal script instead of failing forever. This is what lets #808's
 * e2e spec drive a real "retry succeeds" turn without a second magic string.
 */
import { DEFAULT_MODEL } from "./models";
import type { ComputeProvider, TurnRepo, TurnRequest } from "./provider";
import type { StreamChunk } from "./stream-chunk";

type Sleep = (ms: number) => Promise<void>;

const defaultSleep: Sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const EDITED_FILE = "src/lib/session.ts";

/** A user message containing this text makes the mock turn fail (#808). */
export const MOCK_TURN_ERROR_TRIGGER = "__mock_turn_error__";
/** A user message containing this text runs the approval round-trip (#982). */
export const MOCK_APPROVAL_TRIGGER = "__mock_approval__";

/**
 * The #753 error-class seams, one per first-class failure surface. Same
 * contract as MOCK_TURN_ERROR_TRIGGER (deterministic, hermetic, spent once
 * per session so a Retry succeeds), but each fails at the point — and through
 * the mechanism — its real counterpart would:
 *
 * - provisioning: throws before any content streams, while the turn is still
 *   "Starting sandbox" — a sandbox that never came up (turn-ingest's catch
 *   closes it, exactly like a real create failure).
 * - sandbox died: throws mid-turn, after prose and a tool call already
 *   landed — a VM lost under a running agent; the streamed work survives in
 *   the log, the failure is recorded after it.
 * - stream error: emits an `error` CHUNK mid-stream and ends without `done`
 *   — the provider's own structured error path (#811), exercising the
 *   adapter's error case rather than the ingest catch.
 */
export const MOCK_PROVISION_ERROR_TRIGGER = "__mock_provision_error__";
export const MOCK_SANDBOX_DIED_TRIGGER = "__mock_sandbox_died__";
export const MOCK_STREAM_ERROR_TRIGGER = "__mock_stream_error__";

export const MOCK_PROVISION_ERROR_TEXT =
	"Sandbox provisioning failed — the sandbox never started (mock).";
export const MOCK_SANDBOX_DIED_TEXT =
	"The sandbox died mid-turn — connection to the running agent was lost (mock).";
export const MOCK_STREAM_ERROR_TEXT =
	"The stream broke before the turn finished (mock).";

/** Every failure seam the mock honors; runTurn spends each once per session. */
const ERROR_TRIGGERS = [
	MOCK_TURN_ERROR_TRIGGER,
	MOCK_PROVISION_ERROR_TRIGGER,
	MOCK_SANDBOX_DIED_TRIGGER,
	MOCK_STREAM_ERROR_TRIGGER,
] as const;

const REASONING_TRACE = [
	"The repro says `resumeSession` comes back with undefined for an unknown id, and the test expects a thrown `SessionNotFoundError`.",
	"So the failure is a missing guard: `store.get` returns undefined, and nothing between it and the caller turns that into the error the test wants.",
	"Plan: reproduce the failure first to be sure I'm looking at the right path, read the function, add the null check, then re-run to confirm the suite goes green.",
].join("\n\n");

const FAILING_TEST_OUTPUT = [
	"❯ src/lib/session.test.ts (4 tests | 1 failed) 208ms",
	"  × resumeSession › rejects when the id is unknown",
	"    → expected [Function] to throw SessionNotFoundError",
	"",
	"Test Files  1 failed (1)",
	"     Tests  1 failed | 3 passed (4)",
].join("\n");

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
	model: string = DEFAULT_MODEL,
	repo?: TurnRepo | null,
	requestApproval?: TurnRequest["requestApproval"],
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

	async function* reasoning(text: string): AsyncGenerator<StreamChunk> {
		for (const word of text.split(" ")) {
			yield { type: "reasoning", content: `${word} ` };
			await sleep(22);
		}
	}

	yield { type: "status", content: "Starting sandbox" };
	await sleep(300);

	if (userMessage.includes(MOCK_TURN_ERROR_TRIGGER)) {
		throw new Error("Simulated turn failure (mock provider)");
	}
	// Provisioning failure (#753): the sandbox never comes up — the turn dies
	// before a single content chunk, so the failure card is the whole reply.
	if (userMessage.includes(MOCK_PROVISION_ERROR_TRIGGER)) {
		throw new Error(MOCK_PROVISION_ERROR_TEXT);
	}

	yield { type: "status", content: "Cloning repo" };
	await sleep(300);

	if (userMessage.includes(MOCK_APPROVAL_TRIGGER)) {
		if (!requestApproval) {
			throw new Error("approval broker unavailable for mock approval scenario");
		}
		const pending = await requestApproval({
			toolName: "Edit",
			inputSummary: "Edit src/lib/session.ts to add a missing SessionNotFoundError guard.",
			timeoutMs: 30_000,
		});
		yield {
			type: "approval_request",
			content: "Claude wants to edit src/lib/session.ts.",
			metadata: {
				requestId: pending.requestId,
				toolName: pending.toolName,
				inputSummary: pending.inputSummary,
				expiresAt: pending.expiresAt,
			},
		};
		const resolution = await pending.resolution;
		yield {
			type: "approval_resolved",
			content: resolution.decision,
			metadata: {
				requestId: resolution.requestId,
				decision: resolution.decision,
				resolvedBy: resolution.resolvedBy,
			},
		};
		if (resolution.decision === "deny") {
			yield* prose("Permission was denied, so I stopped before changing files.");
			yield {
				type: "done",
				content: "",
				metadata: {
					durationMs: Date.now() - startedAt,
					tokenCount: Math.ceil(proseChars / 4),
					contextTokens: Math.ceil((userMessage.length + proseChars) / 3.2),
					model,
					...(repo !== undefined ? { repo } : {}),
				},
			};
			return;
		}
		yield* prose("Approved — continuing with the edit path.");
	}

	yield* reasoning(REASONING_TRACE);

	yield* prose(
		`You asked: "${userMessage}". Let me reproduce the failure first.`,
	);

	// Stream error (#753): the provider's own structured `error` chunk lands
	// mid-stream and the turn ends without a `done` — ingest synthesizes the
	// terminal, and deriveTurnError picks the chunk's text up on both paths.
	if (userMessage.includes(MOCK_STREAM_ERROR_TRIGGER)) {
		yield { type: "error", content: MOCK_STREAM_ERROR_TEXT };
		return;
	}

	yield { type: "status", content: "Running `pnpm test session`" };
	yield {
		type: "tool_use",
		content: "Bash",
		metadata: {
			toolUseId: "tool-1",
			toolName: "Bash",
			input: { command: "pnpm test session" },
		},
	};
	await sleep(600);
	yield {
		type: "tool_result",
		content: FAILING_TEST_OUTPUT,
		metadata: { toolUseId: "tool-1", isError: true },
	};

	// Sandbox died (#753): the VM vanishes under a running agent — prose and a
	// tool call already landed, so the log keeps that work ahead of the failure.
	if (userMessage.includes(MOCK_SANDBOX_DIED_TRIGGER)) {
		throw new Error(MOCK_SANDBOX_DIED_TEXT);
	}

	yield* prose(
		"Confirmed — it throws a `TypeError` inside `hydrate` instead of rejecting. Reading the source.",
	);

	yield { type: "status", content: `Reading \`${EDITED_FILE}\`` };
	yield {
		type: "tool_use",
		content: "Read",
		metadata: {
			toolUseId: "tool-2",
			toolName: "Read",
			input: { file_path: EDITED_FILE },
		},
	};
	await sleep(400);
	yield {
		type: "tool_result",
		content:
			"export function resumeSession(id: string) {\n\treturn store.get(id); // BUG: no null check\n}",
		metadata: { toolUseId: "tool-2" },
	};

	yield* prose(
		"Found it — `resumeSession` never handles a missing id. I'll add the guard and re-run the tests.",
	);

	yield { type: "status", content: `Editing \`${EDITED_FILE}\`` };
	yield {
		type: "tool_use",
		content: "Edit",
		metadata: {
			toolUseId: "tool-3",
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
		metadata: { toolUseId: "tool-3", diff: EDIT_DIFF },
	};

	yield { type: "status", content: "Running `pnpm test session`" };
	yield {
		type: "tool_use",
		content: "Bash",
		metadata: {
			toolUseId: "tool-4",
			toolName: "Bash",
			input: { command: "pnpm test session" },
		},
	};
	await sleep(700);
	yield {
		type: "tool_result",
		content: TEST_RUN_OUTPUT,
		metadata: { toolUseId: "tool-4" },
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
			// A plausible context-window figure (conversation so far, ~3.2
			// chars/token) — deterministic so the status line's real-figure wiring
			// is testable without a sandbox call.
			contextTokens: Math.ceil((userMessage.length + proseChars) / 3.2),
			model,
			...(repo !== undefined ? { repo } : {}),
		},
	};
}

/** `sessionId:trigger` pairs whose one guaranteed failure has already fired —
 * dev/e2e-only in-memory state, same lifetime as turn-ingest.ts's
 * `activeTurns`; never pruned. Keyed per trigger so each error class gets its
 * own spend on a session. */
const spentErrorTriggers = new Set<string>();

export const mockProvider: ComputeProvider = {
	id: "mock",
	supportsApprovals: true,
	runTurn: (request: TurnRequest) => {
		let userMessage = request.userMessage;
		for (const trigger of ERROR_TRIGGERS) {
			if (!userMessage.includes(trigger)) continue;
			const spendKey = `${request.sessionId}:${trigger}`;
			if (spentErrorTriggers.has(spendKey)) {
				// Already spent on this session — strip the trigger so the script
				// runs normally instead of failing forever (the persisted user
				// event, appended before the provider ever runs, keeps the original
				// text regardless of what's passed here).
				userMessage = userMessage.split(trigger).join("").trim();
			} else {
				spentErrorTriggers.add(spendKey);
			}
		}
		return mockCodingTurn(
			userMessage,
			undefined,
			request.model,
			request.repo,
			request.requestApproval,
		);
	},
};
