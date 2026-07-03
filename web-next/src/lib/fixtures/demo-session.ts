/*
 * Fixture data for /sessions/demo: the refine-folio prototype's session —
 * one completed coding turn (workings, landed diff, receipt), a follow-up,
 * and an in-progress turn — expressed as AI SDK UIMessages. Also seeds
 * arbitrary-length transcripts for the transcript_render_200 perf scenario.
 */
import type { DynamicToolUIPart } from "ai";
import type { SessionViewData } from "@/components/folio/session-view";
import type { FolioMessage } from "@/components/folio/types";

function completedTool(
	toolCallId: string,
	toolName: string,
	input: Record<string, unknown>,
	output: string | { content: string; summary?: string },
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
					"guard added before hydrate() — see the change below",
				),
				completedTool(
					"tool-4",
					"Bash",
					{ command: "pnpm test" },
					TEST_RUN_OUTPUT,
				),
				{
					type: "data-diff",
					data: {
						file: "src/session/resume.ts",
						additions: 4,
						deletions: 1,
						note: "edit landed · just now",
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
