import { describe, expect, test } from "vitest";
import { mapFullStream } from "./vercel-provider";
import type { StreamChunk } from "./stream-chunk";

type Part = { type: string; [k: string]: unknown };

async function collect(parts: Part[]): Promise<StreamChunk[]> {
	async function* source(): AsyncIterable<Part> {
		for (const part of parts) yield part;
	}
	const out: StreamChunk[] = [];
	for await (const chunk of mapFullStream(source(), 0)) out.push(chunk);
	return out;
}

describe("mapFullStream", () => {
	test("maps deltas and tool parts onto StreamChunks", async () => {
		const chunks = await collect([
			{ type: "start" }, // structural — dropped
			{ type: "reasoning-delta", id: "r1", text: "thinking" },
			{ type: "text-delta", id: "t1", text: "hello " },
			{ type: "text-delta", id: "t1", text: "world" },
			{
				type: "tool-call",
				toolCallId: "c1",
				toolName: "bash",
				input: { command: "ls" },
			},
			{ type: "tool-result", toolCallId: "c1", toolName: "bash", output: "a\nb" },
			{ type: "finish", finishReason: "stop", totalUsage: { outputTokens: 42 } },
		]);

		expect(chunks.map((c) => c.type)).toEqual([
			"reasoning",
			"text",
			"text",
			"tool_use",
			"tool_result",
			"done",
		]);

		const toolUse = chunks.find((c) => c.type === "tool_use");
		expect(toolUse?.content).toBe("bash");
		expect(toolUse?.metadata).toMatchObject({
			toolUseId: "c1",
			toolName: "bash",
			input: { command: "ls" },
		});

		const toolResult = chunks.find((c) => c.type === "tool_result");
		expect(toolResult?.content).toBe("a\nb");
		expect(toolResult?.metadata).toMatchObject({ toolUseId: "c1" });
	});

	test("carries finish outputTokens into the terminal done chunk", async () => {
		const chunks = await collect([
			{ type: "text-delta", id: "t1", text: "hi" },
			{ type: "finish", finishReason: "stop", totalUsage: { outputTokens: 7 } },
		]);
		const done = chunks.at(-1);
		expect(done?.type).toBe("done");
		expect(done?.metadata).toMatchObject({ tokenCount: 7 });
		expect(typeof done?.metadata?.durationMs).toBe("number");
	});

	test("tool-error maps to an errored tool_result", async () => {
		const chunks = await collect([
			{ type: "tool-error", toolCallId: "c1", error: "boom" },
		]);
		const result = chunks.find((c) => c.type === "tool_result");
		expect(result?.content).toBe("boom");
		expect(result?.metadata).toMatchObject({ toolUseId: "c1", isError: true });
	});

	test("error and abort parts both surface as error chunks", async () => {
		const errChunks = await collect([{ type: "error", error: "kaput" }]);
		expect(errChunks[0]).toMatchObject({ type: "error", content: "kaput" });

		const abortChunks = await collect([{ type: "abort", reason: "cancelled" }]);
		expect(abortChunks[0]).toMatchObject({
			type: "error",
			content: "aborted: cancelled",
		});
	});

	test("always ends with exactly one done chunk, even with no finish part", async () => {
		const chunks = await collect([{ type: "text-delta", id: "t1", text: "x" }]);
		const dones = chunks.filter((c) => c.type === "done");
		expect(dones).toHaveLength(1);
		expect(chunks.at(-1)?.type).toBe("done");
		expect(dones[0]?.metadata?.tokenCount).toBeUndefined();
	});
});
