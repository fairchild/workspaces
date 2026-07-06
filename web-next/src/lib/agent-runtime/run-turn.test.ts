import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { type DatabaseHandle, openDatabase } from "../db/client";
import {
	createSession,
	getSession,
	readEvents,
	type Session,
	updateSession,
} from "../db/sessions";
import type { ComputeProvider, TurnRequest } from "./provider";
import { runSessionTurn } from "./run-turn";
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

describe("runSessionTurn", () => {
	test("persists the user event immediately, before the turn is ingested", async () => {
		const handle = freshDb();
		const session = await makeSession(handle);
		const turn = await runSessionTurn(handle, session, "fix it", stubProvider());

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
		const turn = await runSessionTurn(handle, session, "fix it", stubProvider());
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
		const turn = await runSessionTurn(handle, session, "fix it", stubProvider());
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
		const turn = await runSessionTurn(handle, session, "fix it", stubProvider());
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
		const turn = await runSessionTurn(handle, fresh, "again", capturing);
		await drain(turn.stream);
		await turn.ingest;

		expect(seen?.resume).toEqual({
			harnessSessionId: "harness-1",
			resumeState: '{"type":"resume-session"}',
		});
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
		const turn = await runSessionTurn(handle, session, "go", parking);
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
		const turn = await runSessionTurn(handle, session, "go", clearing);
		await drain(turn.stream);
		await turn.ingest;

		const after = await getSession(handle, "s1");
		expect(after?.claudeSessionId).toBeNull();
		expect(after?.resumeState).toBeNull();
	});
});
