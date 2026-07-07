/*
 * Fixture data for /sessions/demo: the refine-folio prototype's session —
 * one completed coding turn (a thinking block, workings, a landed edit whose
 * diff lives in its own Edit ledger row, receipt), a follow-up, and an
 * in-progress turn — expressed as AI SDK UIMessages. Also:
 *   - seededDemoSession: arbitrary-length transcripts for transcript_render_200.
 *   - adversarialSession (?scenario=adversarial): one worst-case turn — a long
 *     reasoning trace, 16 tool calls (one failed), a 100+ line diff, long prose —
 *     the stress test the turn frame, workings, diff-carrying ledger row, and
 *     receipt must hold.
 *   - longTranscriptSession (?scenario=long): 15+ stacked turns to check the
 *     card-in-card framing (recent turn lifted, older ones quiet) at scale.
 */
import type { DynamicToolUIPart } from "ai";
import type { SessionViewData } from "@/components/folio/session-view";
import type {
	DiffCardData,
	DiffLine,
	FolioMessage,
} from "@/components/folio/types";

function completedTool(
	toolCallId: string,
	toolName: string,
	input: Record<string, unknown>,
	output: string | { content: string; summary?: string; diff?: DiffCardData },
): DynamicToolUIPart {
	return {
		type: "dynamic-tool",
		toolCallId,
		toolName,
		state: "output-available",
		input,
		output,
	};
}

function erroredTool(
	toolCallId: string,
	toolName: string,
	input: Record<string, unknown>,
	errorText: string,
): DynamicToolUIPart {
	return {
		type: "dynamic-tool",
		toolCallId,
		toolName,
		state: "output-error",
		input,
		errorText,
	};
}

const TEST_RUN_OUTPUT = [
	"✓ src/session/resume.test.ts   (6 tests)  128ms",
	"✓ src/session/session.test.ts (14 tests)  412ms",
	"✓ src/session/store.test.ts    (8 tests)   96ms",
	"",
	"Test Files  3 passed (3)",
	"     Tests  28 passed (28)",
	"  Duration  1.21s",
].join("\n");

export function demoSession(): SessionViewData {
	const messages: FolioMessage[] = [
		{
			id: "msg-1",
			role: "user",
			metadata: { author: "Michael", stamp: "9:41 am", recede: true },
			parts: [
				{
					type: "text",
					text: "The session-resume path is broken — `resumeSession` comes back with undefined when the id doesn’t exist, and there’s a failing repro in `session.test.ts`. Can you track it down and fix it?",
				},
			],
		},
		{
			id: "msg-2",
			role: "assistant",
			metadata: {
				author: "Claude",
				stamp: "9:42 am",
				focal: true,
				turnStats: { toolCount: 4, tokenCount: 3200, durationMs: 18600 },
			},
			parts: [
				{
					type: "reasoning",
					state: "done",
					text: "The failing test expects `resumeSession` to reject with a `SessionNotFoundError` for an unknown id. Right now it forwards whatever `store.get` returns straight into `hydrate`, so a missing record shows up as `undefined` and blows up one frame later as a `TypeError`.\n\nThe fix is a guard at the boundary: check the record before hydrating and throw the typed error there. I'll read the test and the resume path to be sure of the exact shape, then add the guard and run the suite.",
				},
				{
					type: "text",
					text: "Found it. The failing test — *rejects when the session id is unknown* — expects a `SessionNotFoundError`, but `resumeSession` passes the store’s result straight into `hydrate`. When the id is missing, the record arrives as `undefined` and the failure surfaces one frame too late: a `TypeError` inside `hydrate` instead of a meaningful rejection.",
				},
				completedTool(
					"tool-1",
					"Read",
					{ file_path: "src/session/session.test.ts" },
					{
						content:
							'it("rejects when the session id is unknown", async () => {\n  await expect(resumeSession("sess_missing")).rejects.toThrow(\n    SessionNotFoundError,\n  );\n});',
						summary: "41 lines",
					},
				),
				completedTool(
					"tool-2",
					"Read",
					{ file_path: "src/session/resume.ts" },
					{
						content:
							"export async function resumeSession(id: SessionId): Promise<Session> {\n  const record = await store.get(id);\n  return hydrate(record);\n}",
						summary: "18 lines",
					},
				),
				completedTool(
					"tool-3",
					"Edit",
					{
						file_path: "src/session/resume.ts",
						old_string: "  return hydrate(record);",
						new_string:
							"  if (!record) {\n    throw new SessionNotFoundError(id);\n  }\n  return hydrate(record);",
					},
					{
						content: "guard added before hydrate() — see the change below",
						diff: {
							file: "src/session/resume.ts",
							additions: 4,
							deletions: 1,
							lines: [
								{
									kind: "context",
									text: "  export async function resumeSession(id: SessionId): Promise<Session> {",
								},
								{ kind: "context", text: "    const record = await store.get(id);" },
								{ kind: "del", text: "-   return hydrate(record);" },
								{ kind: "add", text: "+   if (!record) {" },
								{ kind: "add", text: "+     throw new SessionNotFoundError(id);" },
								{ kind: "add", text: "+   }" },
								{ kind: "add", text: "+   return hydrate(record);" },
								{ kind: "context", text: "  }" },
							],
						},
					},
				),
				completedTool(
					"tool-4",
					"Bash",
					{ command: "pnpm test" },
					TEST_RUN_OUTPUT,
				),
				{
					type: "text",
					text: "The guard now rejects at the boundary, before hydration is ever attempted. Full suite is green — 28 tests across three files, including the two that were red.",
				},
			],
		},
		{
			id: "msg-3",
			role: "user",
			metadata: { author: "Michael", stamp: "9:44 am" },
			parts: [
				{
					type: "text",
					text: "Lovely. While you’re in there — add a regression test for the expired-session path; resuming after `expiresAt` should reject the same way.",
				},
			],
		},
	];

	return {
		masthead: {
			repo: "orbit/web",
			branch: "fix/session-resume",
			title: "Fix the failing session-resume test",
			agentName: "Claude",
			stateLabel: "sandbox active",
			live: true,
		},
		messages,
		openToolCallIds: ["tool-4"],
		activeTurn: {
			agentName: "Claude",
			action: "Editing `src/session/session.test.ts`",
			details: [
				{
					state: "done",
					text: "Read src/session/session.test.ts — found the expiry fixtures",
				},
				{
					state: "current",
					text: "Edit src/session/session.test.ts — adding “rejects resuming an expired session”",
				},
			],
		},
		statusLine: { model: "opus-4.8", contextLabel: "2.1k ctx" },
	};
}

/**
 * Deterministic transcript of `messageCount` alternating user/agent
 * messages (agent turns carry a tool part + receipt), representative of a
 * long session for the transcript_render_200 scenario.
 */
export function seededDemoSession(messageCount: number): SessionViewData {
	const base = demoSession();
	const messages: FolioMessage[] = [];
	for (let i = 0; i < messageCount; i++) {
		if (i % 2 === 0) {
			messages.push({
				id: `seed-${i}`,
				role: "user",
				metadata: { author: "Michael", stamp: "9:41 am" },
				parts: [
					{
						type: "text",
						text: `Tighten the retry logic in \`worker-${i}.ts\` — it re-queues failures without any backoff.`,
					},
				],
			});
		} else {
			messages.push({
				id: `seed-${i}`,
				role: "assistant",
				metadata: {
					author: "Claude",
					stamp: "9:42 am",
					turnStats: { toolCount: 1, tokenCount: 800 + i, durationMs: 4200 },
				},
				parts: [
					{
						type: "text",
						text: `Done — \`worker-${i}.ts\` now backs off exponentially before re-queuing, capped at five attempts.`,
					},
					completedTool(
						`seed-tool-${i}`,
						"Read",
						{ file_path: `src/workers/worker-${i}.ts` },
						{
							content: `export const retry = backoff(${i});`,
							summary: "12 lines",
						},
					),
					{
						type: "text",
						text: "The queue drains cleanly in the smoke run.",
					},
				],
			});
		}
	}
	return {
		...base,
		masthead: {
			...base.masthead,
			title: `Seeded transcript — ${messageCount} messages`,
		},
		messages,
		openToolCallIds: undefined,
		activeTurn: undefined,
	};
}

// --- adversarial scale fixture ----------------------------------------------

/** Backend modules the registry refactor touches — drives the big diff + reads. */
const ADVERSARIAL_MODULES = [
	"sessions",
	"workspaces",
	"terminals",
	"diffs",
	"reviews",
	"webhooks",
	"evidence",
	"runners",
	"sandboxes",
	"notifications",
	"auth",
	"billing",
];

const ADVERSARIAL_TEST_OUTPUT = [
	"✓ src/lib/agent-runtime/provider-registry.test.ts (12 tests)  84ms",
	"✓ src/lib/agent-runtime/run-turn.test.ts               (9 tests) 141ms",
	"✓ src/lib/agent-runtime/turn-tail.test.ts             (11 tests) 260ms",
	"✓ src/lib/agent-runtime/backends/*.test.ts            (10 tests) 512ms",
	"",
	"Test Files  4 passed (4)",
	"     Tests  42 passed (42)",
	"  Duration  1.63s",
].join("\n");

/**
 * A 100+ line refactor: a hand-wired provider `switch` replaced by a
 * self-registering map, rippling across a dozen backend modules. Deliberately
 * tall — the stress the diff-carrying ledger row (and the frame around it)
 * has to survive.
 */
function bigRefactorDiff(): DiffCardData {
	const lines: DiffLine[] = [
		{ kind: "context", text: "  // src/lib/agent-runtime/provider-registry.ts" },
		{ kind: "context", text: '  import type { ComputeProvider } from "./provider";' },
		{ kind: "context", text: "" },
		{ kind: "del", text: "- // Every backend hand-wired into one growing switch." },
		{ kind: "del", text: "- export function getProvider(id: string): ComputeProvider {" },
		{ kind: "del", text: "-   switch (id) {" },
	];
	for (const name of ADVERSARIAL_MODULES) {
		lines.push({ kind: "del", text: `-     case "${name}":` });
		lines.push({ kind: "del", text: `-       return ${name}Provider;` });
	}
	lines.push({ kind: "del", text: "-     default:" });
	lines.push({ kind: "del", text: "-       throw new Error(`Unknown provider: ${id}`);" });
	lines.push({ kind: "del", text: "-   }" });
	lines.push({ kind: "del", text: "- }" });
	lines.push({ kind: "context", text: "" });
	const additionsHead = [
		"+ // Providers self-register at import; the registry never edits per backend.",
		"+ const registry = new Map<string, ComputeProvider>();",
		"+",
		"+ export function registerProvider(provider: ComputeProvider): void {",
		"+   if (registry.has(provider.id)) {",
		"+     throw new Error(`Duplicate provider: ${provider.id}`);",
		"+   }",
		"+   registry.set(provider.id, provider);",
		"+ }",
		"+",
		"+ export function getProvider(id: string): ComputeProvider {",
		"+   const provider = registry.get(id);",
		"+   if (!provider) throw new Error(`Unknown provider: ${id}`);",
		"+   return provider;",
		"+ }",
	];
	for (const text of additionsHead) lines.push({ kind: "add", text });
	lines.push({ kind: "context", text: "" });
	for (const name of ADVERSARIAL_MODULES) {
		lines.push({
			kind: "context",
			text: `  // src/lib/agent-runtime/backends/${name}.ts`,
		});
		lines.push({ kind: "del", text: '- import { registerLegacy } from "../legacy";' });
		lines.push({ kind: "del", text: `- registerLegacy("${name}", ${name}Provider);` });
		lines.push({
			kind: "add",
			text: '+ import { registerProvider } from "../provider-registry";',
		});
		lines.push({ kind: "add", text: `+ registerProvider(${name}Provider);` });
	}
	const additions = lines.filter((line) => line.kind === "add").length;
	const deletions = lines.filter((line) => line.kind === "del").length;
	return {
		file: "provider-registry.ts + 12 backends",
		additions,
		deletions,
		note: "refactor landed · just now",
		lines,
	};
}

/** 16 tool calls — a grep, a spread of reads, four edits, a failed typecheck,
 * its green re-run, and the suite. One `output-error` row exercises failure.
 * The turn's aggregate diff (a git-diff-style summary spanning all 13 files)
 * lands on the last Edit call — its ledger row is the diff's one home. */
function adversarialWorkings(diff: DiffCardData): DynamicToolUIPart[] {
	const tools: DynamicToolUIPart[] = [
		completedTool(
			"adv-1",
			"Bash",
			{ command: "rg -l 'getProvider|registerLegacy' src" },
			{
				content: ADVERSARIAL_MODULES.map(
					(m) => `src/lib/agent-runtime/backends/${m}.ts`,
				).join("\n"),
				summary: "14 matches",
			},
		),
		completedTool(
			"adv-2",
			"Read",
			{ file_path: "src/lib/agent-runtime/provider.ts" },
			{ content: "export function getProvider(id: string) { … }", summary: "63 lines" },
		),
		completedTool(
			"adv-3",
			"Read",
			{ file_path: "src/lib/agent-runtime/run-turn.ts" },
			{ content: "const provider = getProvider(session.provider);", summary: "48 lines" },
		),
	];
	ADVERSARIAL_MODULES.slice(0, 6).forEach((name, i) => {
		tools.push(
			completedTool(
				`adv-r${i}`,
				"Read",
				{ file_path: `src/lib/agent-runtime/backends/${name}.ts` },
				{ content: `registerLegacy("${name}", ${name}Provider);`, summary: `${20 + i} lines` },
			),
		);
	});
	tools.push(
		completedTool(
			"adv-e-registry",
			"Edit",
			{
				file_path: "src/lib/agent-runtime/provider-registry.ts",
				old_string: "switch (id) {\n    case …",
				new_string: "const provider = registry.get(id);\nif (!provider) …",
			},
			"switch replaced by a registry lookup",
		),
	);
	const lastEditIndex = 2;
	ADVERSARIAL_MODULES.slice(0, 3).forEach((name, i) => {
		tools.push(
			completedTool(
				`adv-e${i}`,
				"Edit",
				{
					file_path: `src/lib/agent-runtime/backends/${name}.ts`,
					old_string: `registerLegacy("${name}", ${name}Provider);`,
					new_string: `registerProvider(${name}Provider);`,
				},
				i === lastEditIndex ? { content: "self-registration", diff } : "self-registration",
			),
		);
	});
	tools.push(
		erroredTool(
			"adv-typecheck",
			"Bash",
			{ command: "pnpm typecheck" },
			'src/lib/agent-runtime/backends/auth.ts(3,10): error TS2305: Module "../provider-registry" has no exported member "registerProvider".\nsrc/lib/agent-runtime/index.ts(7,1): error TS2308: Module ./provider-registry has already exported a member named getProvider.\n\nFound 2 errors in 2 files.',
		),
	);
	tools.push(
		completedTool(
			"adv-typecheck-2",
			"Bash",
			{ command: "pnpm typecheck" },
			{ content: "tsc --noEmit — no errors", summary: "0 errors" },
		),
	);
	tools.push(
		completedTool(
			"adv-test",
			"Bash",
			{ command: "pnpm test agent-runtime" },
			ADVERSARIAL_TEST_OUTPUT,
		),
	);
	return tools;
}

const ADVERSARIAL_ASK =
	"The provider lookup has turned into a 12-case switch that every new backend has to edit — it’s a merge magnet and it keeps drifting out of sync with the backends themselves. Can you flip it to a self-registering registry: each backend registers itself at import, `getProvider` just does a map lookup, and update every call site + the barrel. Keep the error on an unknown id, and don’t regress the run-turn path.";

const ADVERSARIAL_REASONING =
	"The switch is the coupling point: twelve `case` arms that each new backend has to touch, which is exactly why it drifts. Inverting it means the registry owns a `Map` and exposes `registerProvider`, and each backend calls that at module load — so adding a backend is one import, never an edit here.\n\nThe risk is import-order: a backend only registers when its module is imported, so if `getProvider` runs before the backend is pulled in, the map is empty. The barrel (`index.ts`) already imports every backend for its side effects, so as long as the barrel is the entry the registry is warm by first use. I'll verify that ordering rather than assume it.\n\nPlan: read the current switch and the run-turn call site, write the registry with a duplicate-id guard, convert each backend to self-register, then typecheck (I expect a barrel conflict on the first pass) and run the suite. Keep the unknown-id error identical so nothing downstream changes.";

const ADVERSARIAL_INTRO =
	"This is a coupling problem more than a lookup problem — the switch forces every backend to know about a central file. I’ll invert it so backends register themselves and the registry stays closed for modification. Reading the current shape and the one hot call site first, then making the change across all twelve modules.";

const ADVERSARIAL_CONCLUSION =
	"Done. The switch is gone: `getProvider` is a map lookup with the same unknown-id error, and all twelve backends self-register at import. The first typecheck caught the barrel double-exporting `getProvider` and a missing re-export — both fixed in the same pass — and the full `agent-runtime` suite is green at 42 tests, including the run-turn path you flagged. Adding the thirteenth backend is now a single `registerProvider` call in its own module, with nothing to edit here.";

/**
 * One worst-case turn: a long thinking block, 16 tool calls (one failed), a
 * 100+ line diff, and long prose on both sides — the stress test the turn
 * frame, workings apparatus, a diff-carrying ledger row, reasoning block, and
 * receipt must hold.
 */
export function adversarialSession(): SessionViewData {
	const diff = bigRefactorDiff();
	const messages: FolioMessage[] = [
		{
			id: "adv-user",
			role: "user",
			metadata: { author: "Michael", stamp: "2:14 pm" },
			parts: [{ type: "text", text: ADVERSARIAL_ASK }],
		},
		{
			id: "adv-agent",
			role: "assistant",
			metadata: {
				author: "Claude",
				stamp: "2:31 pm",
				turnStats: {
					toolCount: 16,
					tokenCount: 48200,
					durationMs: 1042000,
					filesChanged: 13,
					additions: diff.additions,
					deletions: diff.deletions,
					testsPassed: 42,
				},
			},
			parts: [
				{ type: "reasoning", state: "done", text: ADVERSARIAL_REASONING },
				{ type: "text", text: ADVERSARIAL_INTRO },
				...adversarialWorkings(diff),
				{ type: "text", text: ADVERSARIAL_CONCLUSION },
			],
		},
	];
	return {
		masthead: {
			repo: "orbit/web",
			branch: "refactor/provider-registry",
			title: "Replace the provider switch with a registry",
			agentName: "Claude",
			stateLabel: "sandbox active",
			live: true,
		},
		messages,
		openToolCallIds: ["adv-test"],
		statusLine: { model: "opus-4.8", contextLabel: "48.2k ctx" },
	};
}

// --- long transcript (card-in-card at scale) --------------------------------

const LONG_ASKS = [
	"The retry logic in the queue worker never backs off — can you add exponential backoff capped at five attempts?",
	"Sessions aren’t expiring; `expiresAt` is set but nothing sweeps them. Add a reaper.",
	"The diff parser chokes on CRLF files. Normalize line endings before parsing.",
	"Add a `--json` flag to the status CLI so we can pipe it.",
	"Webhook signatures aren’t verified. Add HMAC verification with a constant-time compare.",
	"The masthead title overflows on narrow windows — truncate it.",
	"Cache the repo tree between requests; we refetch it on every keystroke.",
	"Add a health endpoint that checks the DB and the sandbox pool.",
	"The evidence uploader retries forever on a 413. Give up after the first and surface it.",
	"Token counts in the receipt are off by the system prompt — subtract it.",
	"Add keyboard nav (j/k) to the transcript.",
	"The dark theme flashes light on first paint. Set the theme before hydration.",
	"Rate-limit the chat route per session.",
	"Collapse consecutive identical statuses in the activity line.",
];

function longAssistantParts(index: number): FolioMessage["parts"] {
	const mod = index % 3;
	if (mod === 0) {
		return [
			{
				type: "reasoning",
				state: "done",
				text: `The failure is narrow — the guard is in the wrong place, so the edge case (${index}) slips past. I'll fix it at the boundary and add a case that pins the behavior.`,
			},
			{
				type: "text",
				text: `Fixed. The edge case now short-circuits before the hot path, and there's a regression test pinning it.`,
			},
			completedTool(
				`lt-tool-${index}`,
				"Bash",
				{ command: "pnpm test" },
				TEST_RUN_OUTPUT,
			),
		];
	}
	if (mod === 1) {
		return [
			{
				type: "text",
				text: `Done — the change is small and contained. Reading the call site first confirmed nothing else depended on the old shape.`,
			},
			completedTool(
				`lt-read-${index}`,
				"Read",
				{ file_path: `src/lib/module-${index}.ts` },
				{ content: `export const value = ${index};`, summary: "24 lines" },
			),
		];
	}
	return [
		{
			type: "text",
			text: `Shipped. One-line fix plus a comment explaining why the order matters here — the trap is subtle enough to earn it.`,
		},
	];
}

/**
 * 15+ stacked turns with the adversarial turn spliced into the middle — the
 * fixture for reviewing the card-in-card framing at scale (recent turn lifted
 * and filled, older turns quiet outlines) and how the thinking block reads when
 * it repeats down a long session.
 */
export function longTranscriptSession(): SessionViewData {
	const base = demoSession();
	const messages: FolioMessage[] = [];
	LONG_ASKS.forEach((ask, i) => {
		messages.push({
			id: `lt-u-${i}`,
			role: "user",
			metadata: { author: "Michael", stamp: "9:4?".replace("?", String(i % 10)) },
			parts: [{ type: "text", text: ask }],
		});
		messages.push({
			id: `lt-a-${i}`,
			role: "assistant",
			metadata: {
				author: "Claude",
				stamp: "9:4?".replace("?", String(i % 10)),
				turnStats: {
					toolCount: i % 3 === 0 ? 1 : i % 3 === 1 ? 1 : 0,
					tokenCount: 900 + i * 130,
					durationMs: 3200 + i * 400,
					testsPassed: i % 3 === 0 ? 28 : undefined,
				},
			},
			parts: longAssistantParts(i),
		});
	});
	// Drop the worst-case turn into the middle so the frame is reviewed with a
	// heavy turn stacked among light ones.
	const adversarial = adversarialSession();
	messages.splice(10, 0, ...adversarial.messages);
	return {
		...base,
		masthead: {
			...base.masthead,
			title: `Long session — ${LONG_ASKS.length + 1} turns`,
		},
		messages,
		openToolCallIds: undefined,
		activeTurn: undefined,
	};
}
