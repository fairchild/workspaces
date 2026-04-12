import { describe, expect, it } from "vitest";
import { parseStreamJsonLine } from "../agent-runtime/vercel-sandbox";

describe("parseStreamJsonLine", () => {
	describe("text_delta events", () => {
		it("extracts text from a text_delta stream event", () => {
			const line = JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_delta",
					index: 0,
					delta: { type: "text_delta", text: "Hello world" },
				},
			});
			expect(parseStreamJsonLine(line)).toEqual({
				type: "text",
				content: "Hello world",
			});
		});

		it("handles empty text delta", () => {
			const line = JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_delta",
					index: 0,
					delta: { type: "text_delta", text: "" },
				},
			});
			expect(parseStreamJsonLine(line)).toEqual({
				type: "text",
				content: "",
			});
		});

		it("preserves whitespace and newlines in text", () => {
			const line = JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_delta",
					index: 0,
					delta: { type: "text_delta", text: "  line1\n  line2\n" },
				},
			});
			expect(parseStreamJsonLine(line)).toEqual({
				type: "text",
				content: "  line1\n  line2\n",
			});
		});
	});

	describe("tool_use events", () => {
		it("extracts tool name from content_block_start", () => {
			const line = JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_start",
					index: 1,
					content_block: { type: "tool_use", id: "toolu_123", name: "Read" },
				},
			});
			expect(parseStreamJsonLine(line)).toEqual({
				type: "tool_use",
				content: "Read",
				metadata: { tool: "Read" },
			});
		});

		it("handles Bash tool", () => {
			const line = JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_start",
					index: 0,
					content_block: { type: "tool_use", id: "toolu_456", name: "Bash" },
				},
			});
			expect(parseStreamJsonLine(line)).toEqual({
				type: "tool_use",
				content: "Bash",
				metadata: { tool: "Bash" },
			});
		});
	});

	describe("ignored events", () => {
		it("returns null for system init events", () => {
			const line = JSON.stringify({
				type: "system",
				subtype: "init",
				session_id: "abc-123",
			});
			expect(parseStreamJsonLine(line)).toBeNull();
		});

		it("returns null for result events", () => {
			const line = JSON.stringify({
				type: "result",
				result: "Final response text",
				session_id: "abc-123",
			});
			expect(parseStreamJsonLine(line)).toBeNull();
		});

		it("returns null for message_start stream events", () => {
			const line = JSON.stringify({
				type: "stream_event",
				event: { type: "message_start", message: { id: "msg_1" } },
			});
			expect(parseStreamJsonLine(line)).toBeNull();
		});

		it("returns null for content_block_stop events", () => {
			const line = JSON.stringify({
				type: "stream_event",
				event: { type: "content_block_stop", index: 0 },
			});
			expect(parseStreamJsonLine(line)).toBeNull();
		});

		it("returns null for stream_event with no event field", () => {
			const line = JSON.stringify({ type: "stream_event" });
			expect(parseStreamJsonLine(line)).toBeNull();
		});

		it("returns null for non-text_delta deltas", () => {
			const line = JSON.stringify({
				type: "stream_event",
				event: {
					type: "content_block_delta",
					delta: { type: "input_json_delta", partial_json: '{"path":' },
				},
			});
			expect(parseStreamJsonLine(line)).toBeNull();
		});
	});

	describe("edge cases", () => {
		it("returns null for empty string", () => {
			expect(parseStreamJsonLine("")).toBeNull();
		});

		it("returns null for whitespace-only string", () => {
			expect(parseStreamJsonLine("   \t  ")).toBeNull();
		});

		it("passes through non-JSON text as a text chunk", () => {
			expect(parseStreamJsonLine("bash: command not found")).toEqual({
				type: "text",
				content: "bash: command not found",
			});
		});

		it("passes through truncated JSON as text", () => {
			expect(parseStreamJsonLine('{"type": "stream_ev')).toEqual({
				type: "text",
				content: '{"type": "stream_ev',
			});
		});

		it("returns null for unknown top-level event type", () => {
			const line = JSON.stringify({ type: "unknown_event", data: 42 });
			expect(parseStreamJsonLine(line)).toBeNull();
		});
	});
});
