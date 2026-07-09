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

	test("config receipt becomes a durable data part", async () => {
		const out = await collect([
			{
				type: "config_receipt",
				content: "Config: 1 file loaded: CLAUDE.md deadbeef",
				metadata: {
					envVar: "WEB_NEXT_CONFIG_FILES",
					loaded: [
						{
							path: "/Users/me/CLAUDE.md",
							basename: "CLAUDE.md",
							sha256: "deadbeef",
						},
					],
					skipped: [
						{
							path: "/Users/me/missing.md",
							basename: "missing.md",
							reason: "file does not exist",
						},
					],
				},
			},
			{ type: "done", content: "" },
		]);

		expect(out).toContainEqual({
			type: "data-config-receipt",
			id: "config-receipt",
			data: {
				loaded: [
					{
						path: "/Users/me/CLAUDE.md",
						basename: "CLAUDE.md",
						sha256: "deadbeef",
					},
				],
				skipped: [
					{
						path: "/Users/me/missing.md",
						basename: "missing.md",
						reason: "file does not exist",
					},
				],
			},
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

	test("a tool_result carrying a diff merges it into that call's own output, not a separate part", async () => {
		const diff = { file: "a.ts", additions: 3, deletions: 1, lines: [] };
		const out = await collect([
			{ type: "tool_use", content: "Edit", metadata: { toolUseId: "t-1" } },
			{ type: "tool_result", content: "ok", metadata: { toolUseId: "t-1", diff } },
			{ type: "done", content: "" },
		]);
		expect(out).toContainEqual({
			type: "tool-output-available",
			toolCallId: "t-1",
			output: { content: "ok", diff },
			dynamic: true,
		});
		expect(out.some((c) => c.type === "data-diff")).toBe(false);
	});

	test("a diff on a structured output object is folded in alongside its other fields", async () => {
		const diff = { file: "a.ts", additions: 1, deletions: 0, lines: [] };
		const out = await collect([
			{ type: "tool_use", content: "Edit", metadata: { toolUseId: "t-1" } },
			{
				type: "tool_result",
				content: "ok",
				metadata: {
					toolUseId: "t-1",
					output: { content: "ok", summary: "landed" },
					diff,
				},
			},
			{ type: "done", content: "" },
		]);
		expect(out).toContainEqual({
			type: "tool-output-available",
			toolCallId: "t-1",
			output: { content: "ok", summary: "landed", diff },
			dynamic: true,
		});
	});

	test("a diff on an object output with no content of its own falls back to the chunk's content, never dropping the diff", async () => {
		const diff = { file: "a.ts", additions: 1, deletions: 0, lines: [] };
		const out = await collect([
			{ type: "tool_use", content: "Edit", metadata: { toolUseId: "t-1" } },
			{
				type: "tool_result",
				content: "fallback text",
				metadata: { toolUseId: "t-1", output: { summary: "landed" }, diff },
			},
			{ type: "done", content: "" },
		]);
		expect(out).toContainEqual({
			type: "tool-output-available",
			toolCallId: "t-1",
			output: { summary: "landed", content: "fallback text", diff },
			dynamic: true,
		});
	});

	test("messageMetadata is emitted on start (no chunks) and finish (all chunks)", async () => {
		const seen: number[] = [];
		const out = [];
		for await (const chunk of toUIMessageChunks(
			[
				{ type: "text", content: "hi" },
				{ type: "done", content: "" },
			],
			{
				messageId: "m",
				messageMetadata: (chunks) => {
					seen.push(chunks.length);
					return { chunksSeen: chunks.length };
				},
			},
		)) {
			out.push(chunk);
		}
		expect(out[0]).toMatchObject({
			type: "start",
			messageMetadata: { chunksSeen: 0 },
		});
		expect(out.at(-1)).toMatchObject({
			type: "finish",
			messageMetadata: { chunksSeen: 2 }, // text + done
		});
		expect(seen).toEqual([0, 2]);
	});

	test("brackets contiguous reasoning chunks into one reasoning part", async () => {
		const out = await collect([
			{ type: "reasoning", content: "Think " },
			{ type: "reasoning", content: "more" },
			{ type: "done", content: "" },
		]);
		expect(out).toEqual([
			{ type: "start", messageId: "msg-1" },
			{ type: "reasoning-start", id: "id-0" },
			{ type: "reasoning-delta", id: "id-0", delta: "Think " },
			{ type: "reasoning-delta", id: "id-0", delta: "more" },
			{ type: "reasoning-end", id: "id-0" },
			{ type: "finish" },
		]);
	});

	test("reasoning and text close each other; they never overlap", async () => {
		const out = await collect([
			{ type: "reasoning", content: "let me think" },
			{ type: "text", content: "here's the answer" },
			{ type: "done", content: "" },
		]);
		// reasoning is closed before the text part opens
		const reasoningEnd = out.findIndex((c) => c.type === "reasoning-end");
		const textStart = out.findIndex((c) => c.type === "text-start");
		expect(reasoningEnd).toBeGreaterThanOrEqual(0);
		expect(textStart).toBeGreaterThan(reasoningEnd);
	});

	test("a tool call closes an open reasoning part", async () => {
		const out = await collect([
			{ type: "reasoning", content: "I should read the file" },
			{ type: "tool_use", content: "Read", metadata: { toolUseId: "t-1" } },
			{ type: "done", content: "" },
		]);
		const reasoningEnd = out.findIndex((c) => c.type === "reasoning-end");
		const toolInput = out.findIndex((c) => c.type === "tool-input-available");
		expect(reasoningEnd).toBeGreaterThanOrEqual(0);
		expect(toolInput).toBeGreaterThan(reasoningEnd);
	});

	test("approval request and resolution update one durable data part", async () => {
		const out = await collect([
			{
				type: "approval_request",
				content: "Claude wants to edit src/lib/session.ts.",
				metadata: {
					requestId: "approval-1",
					toolName: "Edit",
					inputSummary: "Edit src/lib/session.ts",
					expiresAt: "2026-07-08T12:00:00.000Z",
				},
			},
			{
				type: "approval_resolved",
				content: "allow",
				metadata: {
					requestId: "approval-1",
					decision: "allow",
					resolvedBy: "user",
				},
			},
			{ type: "done", content: "" },
		]);
		expect(out).toContainEqual({
			type: "data-approval",
			id: "approval-1",
			data: {
				state: "pending",
				requestId: "approval-1",
				summary: "Claude wants to edit src/lib/session.ts.",
				toolName: "Edit",
				inputSummary: "Edit src/lib/session.ts",
				expiresAt: "2026-07-08T12:00:00.000Z",
			},
		});
		expect(out).toContainEqual({
			type: "data-approval",
			id: "approval-1",
			data: {
				state: "resolved",
				requestId: "approval-1",
				summary: "Claude wants to edit src/lib/session.ts.",
				toolName: "Edit",
				inputSummary: "Edit src/lib/session.ts",
				expiresAt: "2026-07-08T12:00:00.000Z",
				decision: "allow",
				resolvedBy: "user",
			},
		});
	});

	test("an unresolved approval closes as cancelled at turn end (review finding)", async () => {
		const out = await collect([
			{
				type: "approval_request",
				content: "Claude wants to edit a.ts.",
				metadata: {
					requestId: "approval-hanging",
					toolName: "Edit",
					inputSummary: "Edit a.ts",
					expiresAt: "2026-07-08T12:00:00.000Z",
				},
			},
			{
				type: "approval_request",
				content: "Claude wants to run tests.",
				metadata: {
					requestId: "approval-answered",
					toolName: "Bash",
					inputSummary: "pnpm test",
					expiresAt: "2026-07-08T12:00:00.000Z",
				},
			},
			{
				type: "approval_resolved",
				content: "allow",
				metadata: {
					requestId: "approval-answered",
					decision: "allow",
					resolvedBy: "user",
				},
			},
			{ type: "error", content: "turn stopped" },
			{ type: "done", content: "" },
		]);
		const cancelled = out.filter(
			(c) =>
				c.type === "data-approval" &&
				(c.data as { state?: string }).state === "cancelled",
		);
		expect(cancelled).toEqual([
			{
				type: "data-approval",
				id: "approval-hanging",
				data: {
					state: "cancelled",
					requestId: "approval-hanging",
					summary: "Claude wants to edit a.ts.",
					toolName: "Edit",
					inputSummary: "Edit a.ts",
				},
			},
		]);
	});

	test("empty reasoning content opens no part", async () => {
		const out = await collect([
			{ type: "reasoning", content: "" },
			{ type: "done", content: "" },
		]);
		expect(out.some((c) => c.type === "reasoning-start")).toBe(false);
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
