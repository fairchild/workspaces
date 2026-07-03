import { describe, expect, test } from "vitest";
import type { StreamChunk } from "../agent-runtime/stream-chunk";
import { toUIMessageChunks } from "./chunk-adapter";

async function collect(chunks: StreamChunk[]) {
	const ids = (function* () {
		let n = 0;
		while (true) yield `id-${n++}`;
	})();
	const out = [];
	for await (const chunk of toUIMessageChunks(chunks, {
		messageId: "msg-1",
		generateId: () => ids.next().value as string,
	})) {
		out.push(chunk);
	}
	return out;
}

describe("toUIMessageChunks", () => {
	test("brackets contiguous text chunks into one text part", async () => {
		const out = await collect([
			{ type: "text", content: "Hello " },
			{ type: "text", content: "world" },
			{ type: "done", content: "" },
		]);
		expect(out).toEqual([
			{ type: "start", messageId: "msg-1" },
			{ type: "text-start", id: "id-0" },
			{ type: "text-delta", id: "id-0", delta: "Hello " },
			{ type: "text-delta", id: "id-0", delta: "world" },
			{ type: "text-end", id: "id-0" },
			{ type: "finish" },
		]);
	});

	test("tool_use closes text and emits a dynamic tool input", async () => {
		const out = await collect([
			{ type: "text", content: "Let me look." },
			{
				type: "tool_use",
				content: "Read",
				metadata: { toolUseId: "t-1", toolName: "Read", input: { file: "a.ts" } },
			},
			{ type: "done", content: "" },
		]);
		expect(out).toContainEqual({ type: "text-end", id: "id-0" });
		expect(out).toContainEqual({
			type: "tool-input-available",
			toolCallId: "t-1",
			toolName: "Read",
			input: { file: "a.ts" },
			dynamic: true,
		});
	});

	test("tool_result pairs by explicit toolUseId", async () => {
		const out = await collect([
			{ type: "tool_use", content: "Read", metadata: { toolUseId: "t-1" } },
			{ type: "tool_use", content: "Bash", metadata: { toolUseId: "t-2" } },
			{ type: "tool_result", content: "ok", metadata: { toolUseId: "t-2" } },
			{ type: "done", content: "" },
		]);
		expect(out).toContainEqual({
			type: "tool-output-available",
			toolCallId: "t-2",
			output: "ok",
			dynamic: true,
		});
	});

	test("tool_result without id pairs FIFO against unresolved calls", async () => {
		const out = await collect([
			{ type: "tool_use", content: "Read", metadata: { toolUseId: "t-1" } },
			{ type: "tool_use", content: "Bash", metadata: { toolUseId: "t-2" } },
			{ type: "tool_result", content: "first" },
			{ type: "tool_result", content: "second" },
			{ type: "done", content: "" },
		]);
		expect(out).toContainEqual({
			type: "tool-output-available",
			toolCallId: "t-1",
			output: "first",
			dynamic: true,
		});
		expect(out).toContainEqual({
			type: "tool-output-available",
			toolCallId: "t-2",
			output: "second",
			dynamic: true,
		});
	});

	test("error results become tool-output-error", async () => {
		const out = await collect([
			{ type: "tool_use", content: "Bash", metadata: { toolUseId: "t-1" } },
			{
				type: "tool_result",
				content: "exit 1",
				metadata: { toolUseId: "t-1", isError: true },
			},
			{ type: "done", content: "" },
		]);
		expect(out).toContainEqual({
			type: "tool-output-error",
			toolCallId: "t-1",
			errorText: "exit 1",
			dynamic: true,
		});
	});

	test("status becomes a transient data-status chunk", async () => {
		const out = await collect([
			{ type: "status", content: "Starting sandbox" },
			{ type: "done", content: "" },
		]);
		expect(out).toContainEqual({
			type: "data-status",
			data: { message: "Starting sandbox" },
			transient: true,
		});
	});

	test("status does not split an open text part", async () => {
		const out = await collect([
			{ type: "text", content: "a" },
			{ type: "status", content: "still working" },
			{ type: "text", content: "b" },
			{ type: "done", content: "" },
		]);
		const starts = out.filter((c) => c.type === "text-start");
		expect(starts).toHaveLength(1);
	});

	test("error chunk maps to stream error and stream still finishes", async () => {
		const out = await collect([
			{ type: "text", content: "partial" },
			{ type: "error", content: "sandbox died" },
		]);
		expect(out).toContainEqual({ type: "error", errorText: "sandbox died" });
		expect(out.at(-1)).toEqual({ type: "finish" });
	});

	test("source ending without done still closes text and finishes", async () => {
		const out = await collect([{ type: "text", content: "abrupt" }]);
		expect(out).toContainEqual({ type: "text-end", id: "id-0" });
		expect(out.at(-1)).toEqual({ type: "finish" });
	});

	test("text after a tool call starts a new text part", async () => {
		const out = await collect([
			{ type: "text", content: "before" },
			{ type: "tool_use", content: "Read", metadata: { toolUseId: "t-1" } },
			{ type: "text", content: "after" },
			{ type: "done", content: "" },
		]);
		const starts = out.filter((c) => c.type === "text-start");
		expect(starts).toHaveLength(2);
	});
});
