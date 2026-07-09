import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";
import { type DatabaseHandle, openDatabase } from "../db/client";
import {
	appendEvents,
	createSession,
	getSession,
	readEvents,
	type Session,
	updateSession,
} from "../db/sessions";
import {
	cancelQueuedMessage,
	enqueueMessage,
	listQueuedMessages,
} from "../db/queued-messages";
import type { ComputeProvider, TurnRequest } from "./provider";
import {
	ApprovalPolicyUnsupportedError,
	dispatchQueuedTurnIfIdle,
	runSessionTurn,
	type SessionTurn,
	type SessionTurnResult,
} from "./run-turn";
import { startNextQueuedTurn } from "./turn-ingest";
import {
	MOCK_PROVISION_ERROR_TRIGGER,
	MOCK_TURN_ERROR_TRIGGER,
} from "./mock-provider";
import type { StreamChunk } from "./stream-chunk";

// Same throwaway on-disk DB pattern as sessions.test.ts.
let open: DatabaseHandle | undefined;
let dir: string | undefined;

function freshDb(): DatabaseHandle {
	dir = mkdtempSync(join(tmpdir(), "web-next-turn-"));
	open = openDatabase(`file:${join(dir, "test.db")}`);
	return open;
}

afterEach(async () => {
	vi.useRealTimers();
	await open?.db.destroy();
	open = undefined;
	if (dir) rmSync(dir, { recursive: true, force: true });
	dir = undefined;
});

/** An instant scripted provider: echo text, one tool call+result, done. */
const stubTurn: StreamChunk[] = [
	{ type: "text", content: "On it. " },
	{
		type: "tool_use",
		content: "Read",
		metadata: { toolUseId: "t-1", toolName: "Read", input: { file_path: "a.ts" } },
	},
	{ type: "tool_result", content: "contents", metadata: { toolUseId: "t-1" } },
	{ type: "done", content: "", metadata: { durationMs: 12 } },
];

function stubProvider(chunks: StreamChunk[] = stubTurn): ComputeProvider {
	return {
		id: "stub",
		runTurn: async function* () {
			yield* chunks;
		},
	};
}

async function makeSession(handle: DatabaseHandle): Promise<Session> {
	return createSession(handle, { id: "s1", provider: "mock" });
}

async function drain(stream: ReadableStream<unknown>): Promise<unknown[]> {
	const out: unknown[] = [];
	const reader = stream.getReader();
	for (;;) {
		const { value, done } = await reader.read();
		if (done) return out;
		out.push(value);
	}
}

async function waitForUserContents(
	handle: DatabaseHandle,
	sessionId: string,
	count: number,
): Promise<string[]> {
	for (let attempt = 0; attempt < 100; attempt += 1) {
		const events = await readEvents(handle, sessionId);
		const users = events
			.filter((event) => event.role === "user")
			.map((event) => event.chunk.content);
		const doneCount = events.filter(
			(event) => event.role === "assistant" && event.chunk.type === "done",
		).length;
		if (users.length >= count && doneCount >= count) return users;
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
	throw new Error(`timed out waiting for ${count} user events`);
}

function started(result: SessionTurnResult): SessionTurn {
	expect(result.kind).toBe("started");
	return result as SessionTurn;
}

describe("runSessionTurn", () => {
	test("persists the user event immediately, before the turn is ingested", async () => {
		const handle = freshDb();
		const session = await makeSession(handle);
		const turn = started(await runSessionTurn(handle, session, "fix it", stubProvider()));

		// The user event exists as soon as runSessionTurn returns — detached
		// ingest of the assistant reply runs independently.
		const events = await readEvents(handle, "s1");
		expect(events[0]).toMatchObject({
			seq: 1,
			role: "user",
			chunk: { type: "text", content: "fix it" },
		});
		expect(turn.fromSeq).toBe(2);
		await turn.ingest;
	});

	test("the detached ingest appends the whole turn to the log, in order", async () => {
		const handle = freshDb();
		const session = await makeSession(handle);
		// Drop the stream on the floor — the turn must still complete because
		// ingest is independent of any reader.
		const turn = started(await runSessionTurn(handle, session, "fix it", stubProvider()));
		await turn.stream.cancel();
		await turn.ingest;

		const events = await readEvents(handle, "s1");
		expect(events.map((event) => [event.seq, event.role, event.chunk.type])).toEqual([
			[1, "user", "text"],
			[2, "assistant", "text"],
			[3, "assistant", "tool_use"],
			[4, "assistant", "tool_result"],
			[5, "assistant", "done"],
		]);
	});

	test("the live stream tails the log with ids matching its projection", async () => {
		const handle = freshDb();
		const session = await makeSession(handle);
		const turn = started(await runSessionTurn(handle, session, "fix it", stubProvider()));
		const chunks = (await drain(turn.stream)) as {
			type: string;
			messageId?: string;
			id?: string;
		}[];
		await turn.ingest;

		// The assistant message id is `${sessionId}:${firstAssistantSeq}` —
		// what projectSessionEvents derives from the same log on reload.
		expect(chunks[0]).toMatchObject({ type: "start", messageId: "s1:2" });
		const textStart = chunks.find((chunk) => chunk.type === "text-start");
		expect(textStart?.id).toBe("s1:2:p0");
	});

	test("the finished stream carries the derived turn receipt", async () => {
		const handle = freshDb();
		const session = await makeSession(handle);
		const turn = started(await runSessionTurn(handle, session, "fix it", stubProvider()));
		const chunks = (await drain(turn.stream)) as {
			type: string;
			messageMetadata?: { author?: string; turnStats?: { toolCount: number } };
		}[];
		await turn.ingest;

		const finish = chunks.find((chunk) => chunk.type === "finish");
		expect(finish?.messageMetadata).toMatchObject({
			author: "Claude",
			turnStats: { toolCount: 1, durationMs: 12 },
		});
	});

	test("refuses a non-auto policy on a provider without approval support (review finding)", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "s-ask",
			provider: "mock",
			approvalPolicy: "ask-writes",
		});
		// stubProvider has no supportsApprovals flag — the turn must be refused
		// up front, never run with tool calls silently unguarded.
		await expect(
			runSessionTurn(handle, session, "hi", stubProvider()),
		).rejects.toThrow(ApprovalPolicyUnsupportedError);
	});

	test("rejects an unknown provider before touching the log", async () => {
		const handle = freshDb();
		const session = await createSession(handle, { id: "s2", provider: "nope" });
		await expect(runSessionTurn(handle, session, "hi")).rejects.toThrow(
			"Unknown compute provider: nope",
		);
		expect(await readEvents(handle, "s2")).toEqual([]);
	});

	test("passes a stored resume handle into the provider request", async () => {
		const handle = freshDb();
		await createSession(handle, { id: "s1", provider: "vercel" });
		await updateSession(handle, "s1", {
			claudeSessionId: "harness-1",
			resumeState: '{"type":"resume-session"}',
		});
		const fresh = (await getSession(handle, "s1")) as Session;

		let seen: TurnRequest | undefined;
		const capturing: ComputeProvider = {
			id: "vercel",
			runTurn: async function* (request) {
				seen = request;
				yield { type: "done", content: "" } as StreamChunk;
			},
		};
		const turn = started(await runSessionTurn(handle, fresh, "again", capturing));
		await drain(turn.stream);
		await turn.ingest;

		expect(seen?.resume).toEqual({
			harnessSessionId: "harness-1",
			resumeState: '{"type":"resume-session"}',
		});
	});

	test("threads the session's selected model into the provider request (#824)", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "s1",
			provider: "vercel",
			model: "claude-opus-4-8",
		});

		let seen: TurnRequest | undefined;
		const capturing: ComputeProvider = {
			id: "vercel",
			runTurn: async function* (request) {
				seen = request;
				yield { type: "done", content: "" } as StreamChunk;
			},
		};
		const turn = started(await runSessionTurn(handle, session, "go", capturing));
		await drain(turn.stream);
		await turn.ingest;

		expect(seen?.model).toBe("claude-opus-4-8");
	});

	test("persists a parked handle from the done chunk and strips it from the log", async () => {
		const handle = freshDb();
		const session = await createSession(handle, { id: "s1", provider: "vercel" });
		const parking = stubProvider([
			{ type: "text", content: "done" },
			{
				type: "done",
				content: "",
				metadata: {
					durationMs: 5,
					resume: { harnessSessionId: "harness-9", resumeState: '{"data":1}' },
				},
			},
		]);
		const turn = started(await runSessionTurn(handle, session, "go", parking));
		await drain(turn.stream);
		await turn.ingest;

		// The handle landed on the session row for the next turn to resume from.
		const after = await getSession(handle, "s1");
		expect(after?.claudeSessionId).toBe("harness-9");
		expect(after?.resumeState).toBe('{"data":1}');

		// …and the private handle is not left in the transcript's done event.
		const events = await readEvents(handle, "s1");
		const done = events.find((e) => e.chunk.type === "done");
		expect(done?.chunk.metadata).not.toHaveProperty("resume");
		expect(done?.chunk.metadata).toMatchObject({ durationMs: 5 });
	});

	test("a null resume on the done chunk clears a stale stored handle", async () => {
		const handle = freshDb();
		const session = await createSession(handle, { id: "s1", provider: "vercel" });
		await updateSession(handle, "s1", {
			claudeSessionId: "old",
			resumeState: '{"stale":true}',
		});
		const clearing = stubProvider([
			{ type: "done", content: "", metadata: { resume: null } },
		]);
		const turn = started(await runSessionTurn(handle, session, "go", clearing));
		await drain(turn.stream);
		await turn.ingest;

		const after = await getSession(handle, "s1");
		expect(after?.claudeSessionId).toBeNull();
		expect(after?.resumeState).toBeNull();
	});

	test("a send while a turn is running queues without touching session_events (#984)", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "queue-conflict",
			provider: "mock",
		});
		// A provider that stays open until the test releases it.
		let release!: () => void;
		const gate = new Promise<void>((r) => (release = r));
		const slow: ComputeProvider = {
			id: "slow",
			runTurn: async function* () {
				yield { type: "text", content: "working " } as StreamChunk;
				await gate;
				yield { type: "done", content: "" } as StreamChunk;
			},
		};

		const first = started(await runSessionTurn(handle, session, "one", slow));
		const queuedText = `two ${MOCK_TURN_ERROR_TRIGGER}`;
		const queued = await runSessionTurn(handle, session, queuedText, stubProvider());
		expect(queued).toMatchObject({ kind: "queued", position: 1 });
		// The queued send persisted nothing to session_events while the live
		// turn's seq range is still open.
		const during = await readEvents(handle, session.id);
		expect(during.filter((e) => e.role === "user")).toHaveLength(1);

		release();
		await first.ingest;
		// The queued row dispatched as the next normal user turn after the first
		// turn closed.
		await expect(waitForUserContents(handle, session.id, 2)).resolves.toEqual([
			"one",
			queuedText,
		]);
	});

	test("queued turns dispatch oldest-first after the running turn settles (#984)", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "queue-order",
			provider: "mock",
		});
		let release!: () => void;
		const gate = new Promise<void>((r) => (release = r));
		const slow: ComputeProvider = {
			id: "slow",
			runTurn: async function* () {
				yield { type: "text", content: "working " } as StreamChunk;
				await gate;
				yield { type: "done", content: "" } as StreamChunk;
			},
		};

		const first = started(await runSessionTurn(handle, session, "one", slow));
		const secondText = `two ${MOCK_TURN_ERROR_TRIGGER}`;
		const thirdText = `three ${MOCK_PROVISION_ERROR_TRIGGER}`;
		await runSessionTurn(handle, session, secondText, stubProvider());
		await runSessionTurn(handle, session, thirdText, stubProvider());
		expect((await listQueuedMessages(handle, session.id)).map((m) => m.text)).toEqual([
			secondText,
			thirdText,
		]);

		release();
		await first.ingest;
		const users = await waitForUserContents(handle, session.id, 3);
		expect(users).toEqual(["one", secondText, thirdText]);
		expect(await listQueuedMessages(handle, session.id)).toEqual([]);
	});

	test("concurrent continuation and GET sweep dispatch exactly one queued turn first (#984)", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "queue-concurrent",
			provider: "mock",
		});
		const firstText = `first ${MOCK_TURN_ERROR_TRIGGER}`;
		const secondText = `second ${MOCK_PROVISION_ERROR_TRIGGER}`;
		await enqueueMessage(handle, session.id, firstText);
		await enqueueMessage(handle, session.id, secondText);

		const [continued, swept] = await Promise.all([
			startNextQueuedTurn(handle, session.id),
			dispatchQueuedTurnIfIdle(handle, session),
		]);

		const startedTurns = [continued, swept].filter(
			(turn): turn is NonNullable<typeof turn> => turn !== null,
		);
		expect(startedTurns).toHaveLength(1);
		await startedTurns[0].ingest;
		const users = await waitForUserContents(handle, session.id, 2);
		expect(users).toEqual([firstText, secondText]);
	});

	test("a direct POST behind a pending queue row enqueues instead of jumping ahead (#984)", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "queue-direct-behind-pending",
			provider: "mock",
		});
		const firstText = "already queued";
		const directText = "new direct post";
		await enqueueMessage(handle, session.id, firstText);

		const result = await runSessionTurn(handle, session, directText, stubProvider());

		expect(result).toMatchObject({ kind: "queued", position: 2 });
		expect((await readEvents(handle, session.id)).filter((e) => e.role === "user")).toEqual(
			[],
		);
		expect((await listQueuedMessages(handle, session.id)).map((m) => m.text)).toEqual([
			firstText,
			directText,
		]);
	});

	test("a post-claim start failure leaves queued text visible in session_events (#984)", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "queue-stranded-claim",
			provider: "nope",
		});
		const queuedText = "dispatch me once";
		await enqueueMessage(handle, session.id, queuedText);

		await expect(dispatchQueuedTurnIfIdle(handle, session)).rejects.toThrow(
			"Unknown compute provider: nope",
		);

		expect(await listQueuedMessages(handle, session.id)).toEqual([]);
		const users = (await readEvents(handle, session.id))
			.filter((event) => event.role === "user")
			.map((event) => event.chunk.content);
		expect(users).toEqual([queuedText]);
	});

	test("same-millisecond queued messages dispatch in insertion order (#984)", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "queue-fifo-tie",
			provider: "mock",
		});
		vi.useFakeTimers();
		vi.setSystemTime(new Date("2026-01-01T00:00:00.000Z"));
		const firstText = `same-ms first ${MOCK_TURN_ERROR_TRIGGER}`;
		const secondText = `same-ms second ${MOCK_PROVISION_ERROR_TRIGGER}`;
		const first = await enqueueMessage(handle, session.id, firstText);
		const second = await enqueueMessage(handle, session.id, secondText);
		vi.useRealTimers();

		expect(first.queuedAt).toBe(second.queuedAt);
		expect((await listQueuedMessages(handle, session.id)).map((m) => m.text)).toEqual([
			firstText,
			secondText,
		]);
		const turn = await dispatchQueuedTurnIfIdle(handle, session);
		expect(turn?.kind).toBe("started");
		await turn?.ingest;
		const users = await waitForUserContents(handle, session.id, 2);
		expect(users).toEqual([firstText, secondText]);
	});

	test("canceling an undispatched queued turn prevents dispatch (#984)", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "queue-cancel",
			provider: "mock",
		});
		let release!: () => void;
		const gate = new Promise<void>((r) => (release = r));
		const slow: ComputeProvider = {
			id: "slow",
			runTurn: async function* () {
				yield { type: "text", content: "working " } as StreamChunk;
				await gate;
				yield { type: "done", content: "" } as StreamChunk;
			},
		};

		const first = started(await runSessionTurn(handle, session, "one", slow));
		const queued = await runSessionTurn(handle, session, "two", stubProvider());
		expect(queued.kind).toBe("queued");
		if (queued.kind !== "queued") throw new Error("expected queued result");

		await expect(cancelQueuedMessage(handle, session.id, queued.queueId)).resolves.toBe(
			"canceled",
		);
		release();
		await first.ingest;
		const users = (await readEvents(handle, session.id))
			.filter((event) => event.role === "user")
			.map((event) => event.chunk.content);
		expect(users).toEqual(["one"]);
	});

	test("dispatched queued turns cannot be canceled, and idle fallback starts them (#984)", async () => {
		const handle = freshDb();
		const session = await createSession(handle, {
			id: "queue-fallback",
			provider: "mock",
		});
		const queuedText = `handoff turn ${MOCK_TURN_ERROR_TRIGGER}`;
		const queued = await enqueueMessage(handle, session.id, queuedText);

		const fallback = await dispatchQueuedTurnIfIdle(handle, session);
		expect(fallback?.kind).toBe("started");
		await expect(cancelQueuedMessage(handle, session.id, queued.queueId)).resolves.toBe(
			"dispatched",
		);
		await fallback?.ingest;

		const users = (await readEvents(handle, session.id))
			.filter((event) => event.role === "user")
			.map((event) => event.chunk.content);
		expect(users).toEqual([queuedText]);
	});

	test("titles the session from the first turn's message, before the tab could close (#823)", async () => {
		const handle = freshDb();
		const session = await makeSession(handle);
		const turn = started(await runSessionTurn(handle, session, "  Fix   the   login   bug  ", stubProvider()));
		// The title is set as soon as runSessionTurn returns — synchronously with
		// the durable user-event append, not waiting on the detached ingest.
		expect((await getSession(handle, "s1"))?.title).toBe("Fix the login bug");
		await turn.ingest;
	});

	test("a second turn never overwrites the title from the first (#823)", async () => {
		const handle = freshDb();
		const session = await makeSession(handle);
		const first = started(await runSessionTurn(handle, session, "Fix the login bug", stubProvider()));
		await first.ingest;

		const resessioned = (await getSession(handle, "s1")) as Session;
		const second = started(await runSessionTurn(handle, resessioned, "Now add a test", stubProvider()));
		await second.ingest;

		expect((await getSession(handle, "s1"))?.title).toBe("Fix the login bug");
	});

	test("an empty first message leaves the session untitled for a later turn to name (#823)", async () => {
		const handle = freshDb();
		const session = await makeSession(handle);
		const first = started(await runSessionTurn(handle, session, "   ", stubProvider()));
		await first.ingest;
		expect((await getSession(handle, "s1"))?.title).toBe("");

		const resessioned = (await getSession(handle, "s1")) as Session;
		const second = started(await runSessionTurn(handle, resessioned, "Fix the real bug", stubProvider()));
		await second.ingest;
		expect((await getSession(handle, "s1"))?.title).toBe("Fix the real bug");
	});

	test("a user-edited title survives a later turn (#823)", async () => {
		const handle = freshDb();
		await makeSession(handle);
		await updateSession(handle, "s1", { title: "My own title" });
		const resessioned = (await getSession(handle, "s1")) as Session;

		const turn = started(await runSessionTurn(handle, resessioned, "Fix the login bug", stubProvider()));
		await turn.ingest;
		expect((await getSession(handle, "s1"))?.title).toBe("My own title");
	});

	test("a stale unfinished predecessor is closed durably before a new send (#811)", async () => {
		const handle = freshDb();
		const session = await makeSession(handle);
		await appendEvents(handle, "s1", [
			{ role: "user", chunk: { type: "text", content: "old" } },
			{ role: "assistant", chunk: { type: "text", content: "half " } },
		]);
		// Backdate: the runner died long ago and never wrote a done.
		const old = new Date(Date.now() - 180_000).toISOString();
		await handle.client.execute({
			sql: "UPDATE session_events SET created_at = ? WHERE session_id = 's1'",
			args: [old],
		});

		const turn = started(await runSessionTurn(handle, session, "new", stubProvider()));
		await turn.ingest;
		const events = await readEvents(handle, "s1");
		// The old run gained error+done BEFORE the new user event — every
		// assistant run in the log terminates.
		expect(events.map((e) => e.chunk.type).slice(0, 5)).toEqual([
			"text", "text", "error", "done", "text",
		]);
		expect(events[4]).toMatchObject({ role: "user" });
	});
});
