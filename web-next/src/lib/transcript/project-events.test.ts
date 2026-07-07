import { describe, expect, test } from "vitest";
import {
	type ProjectedEvent,
	projectSessionEvents,
} from "./project-events";

/**
 * Terse builders so the fixtures read as a transcript, not a wall of object
 * literals. `u` = a user event, `a` = an assistant event; seq is auto-assigned
 * in array order but each test can shuffle to prove ordering independence.
 */
function u(seq: number, content: string): ProjectedEvent {
	return { seq, role: "user", chunk: { type: "text", content } };
}
function a(
	seq: number,
	type: ProjectedEvent["chunk"]["type"],
	content: string,
	metadata?: Record<string, unknown>,
): ProjectedEvent {
	return { seq, role: "assistant", chunk: { type, content, metadata } };
}

describe("projectSessionEvents", () => {
	test("projects a full user+assistant turn (the canonical example)", async () => {
		const events: ProjectedEvent[] = [
			u(1, "Fix the null check in resumeSession"),
			a(2, "status", "Starting sandbox"),
			a(3, "text", "Let me read the file. "),
			a(4, "tool_use", "Read", {
				toolUseId: "t-1",
				toolName: "Read",
				input: { file_path: "session.ts" },
			}),
			a(5, "tool_result", "return store.get(id);", { toolUseId: "t-1" }),
			a(6, "text", "Found the bug."),
			a(7, "done", ""),
		];

		// This asserted value IS the projection example: same log in, same
		// UIMessage[] out, every id derived from session id + seq. Completed
		// assistant turns carry the derived Folio metadata (author + receipt).
		expect(await projectSessionEvents("sess-1", events)).toEqual([
			{
				id: "sess-1:1",
				role: "user",
				parts: [
					{ type: "text", text: "Fix the null check in resumeSession", state: "done" },
				],
			},
			{
				id: "sess-1:2",
				role: "assistant",
				metadata: {
					author: "Claude",
					turnStats: { toolCount: 1, durationMs: 0 },
				},
				parts: [
					{ type: "text", text: "Let me read the file. ", state: "done" },
					{
						type: "dynamic-tool",
						toolName: "Read",
						toolCallId: "t-1",
						state: "output-available",
						input: { file_path: "session.ts" },
						output: "return store.get(id);",
					},
					{ type: "text", text: "Found the bug.", state: "done" },
				],
			},
		]);
	});

	test("is deterministic and order-independent (shuffled seq → same output)", async () => {
		const ordered: ProjectedEvent[] = [
			u(1, "hi"),
			a(2, "text", "hello"),
			a(3, "done", ""),
		];
		const shuffled = [ordered[2], ordered[0], ordered[1]];
		const fromOrdered = await projectSessionEvents("s", ordered);
		const fromShuffled = await projectSessionEvents("s", shuffled);
		expect(fromShuffled).toEqual(fromOrdered);
		expect(fromOrdered.map((m) => m.id)).toEqual(["s:1", "s:2"]);
	});

	test("pairs tool results by explicit toolUseId across two calls", async () => {
		const messages = await projectSessionEvents("s", [
			a(1, "tool_use", "Read", { toolUseId: "t-1", toolName: "Read" }),
			a(2, "tool_use", "Bash", { toolUseId: "t-2", toolName: "Bash" }),
			a(3, "tool_result", "second", { toolUseId: "t-2" }),
			a(4, "tool_result", "first", { toolUseId: "t-1" }),
			a(5, "done", ""),
		]);
		const parts = messages[0].parts.filter((p) => p.type === "dynamic-tool");
		expect(parts).toMatchObject([
			{ toolCallId: "t-1", state: "output-available", output: "first" },
			{ toolCallId: "t-2", state: "output-available", output: "second" },
		]);
	});

	test("pairs a tool result with no id FIFO against the open call", async () => {
		const messages = await projectSessionEvents("s", [
			a(1, "tool_use", "Bash", { toolUseId: "t-1", toolName: "Bash" }),
			a(2, "tool_result", "done"),
			a(3, "done", ""),
		]);
		expect(messages[0].parts).toMatchObject([
			{ type: "dynamic-tool", toolCallId: "t-1", state: "output-available", output: "done" },
		]);
	});

	test("maps an error tool result to an errored tool part", async () => {
		const messages = await projectSessionEvents("s", [
			a(1, "tool_use", "Bash", { toolUseId: "t-1", toolName: "Bash" }),
			a(2, "tool_result", "exit 1", { toolUseId: "t-1", isError: true }),
			a(3, "done", ""),
		]);
		expect(messages[0].parts).toMatchObject([
			{ type: "dynamic-tool", state: "output-error", errorText: "exit 1" },
		]);
	});

	test("a stream error preserves preceding text and never throws", async () => {
		const messages = await projectSessionEvents("s", [
			u(1, "go"),
			a(2, "text", "partial answer"),
			a(3, "error", "sandbox died"),
		]);
		expect(messages).toHaveLength(2);
		expect(messages[1]).toMatchObject({
			role: "assistant",
			parts: [{ type: "text", text: "partial answer" }],
		});
	});

	test("an unfinished turn projects without a receipt; a done one with it", async () => {
		const [unfinished] = await projectSessionEvents("s", [
			a(1, "text", "still going"),
		]);
		expect(unfinished.metadata).toEqual({ author: "Claude" });

		const [complete] = await projectSessionEvents("s", [
			a(1, "text", "done now"),
			a(2, "done", "", { durationMs: 6200, tokenCount: 1100 }),
		]);
		expect(complete.metadata).toEqual({
			author: "Claude",
			turnStats: { toolCount: 0, durationMs: 6200, tokenCount: 1100 },
		});
	});

	test("a diff-carrying tool result projects into that call's own dynamic-tool part", async () => {
		const diff = { file: "a.ts", additions: 3, deletions: 1, lines: [] };
		const messages = await projectSessionEvents("s", [
			a(1, "tool_use", "Edit", { toolUseId: "t-1", toolName: "Edit" }),
			a(2, "tool_result", "ok", { toolUseId: "t-1", diff }),
			a(3, "done", ""),
		]);
		expect(messages[0].parts).toContainEqual(
			expect.objectContaining({
				type: "dynamic-tool",
				toolCallId: "t-1",
				output: { content: "ok", diff },
			}),
		);
		expect(messages[0].parts.some((part) => part.type === "data-diff")).toBe(false);
	});

	test("projects a reasoning event into a reasoning part before the answer", async () => {
		const messages = await projectSessionEvents("s", [
			u(1, "why is it failing?"),
			a(2, "reasoning", "The guard is missing, so undefined slips through."),
			a(3, "text", "Found it."),
			a(4, "done", ""),
		]);
		expect(messages[1]).toMatchObject({
			role: "assistant",
			parts: [
				{
					type: "reasoning",
					text: "The guard is missing, so undefined slips through.",
					state: "done",
				},
				{ type: "text", text: "Found it." },
			],
		});
	});

	test("a reasoning-only turn still renders (it is a real part)", async () => {
		const messages = await projectSessionEvents("s", [
			a(1, "reasoning", "thinking out loud"),
			a(2, "done", ""),
		]);
		expect(messages).toHaveLength(1);
		expect(messages[0].parts).toMatchObject([
			{ type: "reasoning", text: "thinking out loud" },
		]);
	});

	test("interleaves multiple user+assistant turns in one log", async () => {
		const messages = await projectSessionEvents("s", [
			u(1, "first question"),
			a(2, "text", "first answer"),
			a(3, "done", ""),
			u(4, "second question"),
			a(5, "text", "second answer"),
			a(6, "done", ""),
		]);
		expect(
			messages.map((m) => ({ id: m.id, role: m.role })),
		).toEqual([
			{ id: "s:1", role: "user" },
			{ id: "s:2", role: "assistant" },
			{ id: "s:4", role: "user" },
			{ id: "s:5", role: "assistant" },
		]);
	});

	test("splits back-to-back assistant turns at each done chunk", async () => {
		const messages = await projectSessionEvents("s", [
			a(1, "text", "turn one"),
			a(2, "done", ""),
			a(3, "text", "turn two"),
			a(4, "done", ""),
		]);
		expect(messages.map((m) => m.id)).toEqual(["s:1", "s:3"]);
		expect(messages.every((m) => m.role === "assistant")).toBe(true);
	});

	test("omits an assistant turn that yields no renderable parts", async () => {
		const messages = await projectSessionEvents("s", [
			u(1, "hi"),
			a(2, "status", "provisioning"),
			a(3, "done", ""),
		]);
		expect(messages.map((m) => m.role)).toEqual(["user"]);
	});

	test("concatenates consecutive user events into one message", async () => {
		const messages = await projectSessionEvents("s", [
			u(1, "part one "),
			u(2, "part two"),
			a(3, "text", "ok"),
			a(4, "done", ""),
		]);
		expect(messages[0]).toEqual({
			id: "s:1",
			role: "user",
			parts: [{ type: "text", text: "part one part two", state: "done" }],
		});
	});
});
