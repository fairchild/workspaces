import { describe, expect, test } from "vitest";
import type { ProjectedEvent } from "./project-events";
import {
	projectReplayContext,
	REPLAY_CONTEXT_TRUNCATED_MARKER,
} from "./replay-context";

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

describe("projectReplayContext", () => {
	test("returns null for an empty session log", () => {
		expect(projectReplayContext([])).toBeNull();
	});

	test("replays user messages and assistant text while eliding operational chunks", () => {
		const replay = projectReplayContext([
			u(1, "Fix the failed resume"),
			a(2, "status", "Starting sandbox"),
			a(3, "reasoning", "I should inspect the provider."),
			a(4, "text", "I found the missing guard. "),
			a(5, "tool_use", "Read", {
				toolUseId: "t-1",
				toolName: "Read",
			}),
			a(6, "tool_result", "source text", { toolUseId: "t-1" }),
			a(7, "text", "The fix is in."),
			a(8, "error", "ignored failure text"),
			a(9, "done", ""),
		]);

		expect(replay).toBe(
			[
				"User: Fix the failed resume",
				"Assistant: I found the missing guard. The fix is in.",
			].join("\n\n"),
		);
		expect(replay).not.toContain("Starting sandbox");
		expect(replay).not.toContain("I should inspect");
		expect(replay).not.toContain("source text");
		expect(replay).not.toContain("ignored failure");
	});

	test("orders events by seq before formatting the dialogue", () => {
		const replay = projectReplayContext([
			a(3, "done", ""),
			a(2, "text", "Hello."),
			u(1, "Hi"),
		]);

		expect(replay).toBe("User: Hi\n\nAssistant: Hello.");
	});

	test("truncates oldest dialogue first and stays within the character cap", () => {
		const replay = projectReplayContext(
			[
				u(1, "old request that should fall away"),
				a(2, "text", "old answer that should fall away"),
				a(3, "done", ""),
				u(4, "new request with important details"),
				a(5, "text", "new answer with the useful plan"),
				a(6, "done", ""),
			],
			120,
		);

		expect(replay).not.toBeNull();
		expect(replay?.length).toBeLessThanOrEqual(120);
		expect(replay?.startsWith(REPLAY_CONTEXT_TRUNCATED_MARKER)).toBe(true);
		expect(replay).toContain("new request with important details");
		expect(replay).toContain("new answer with the useful plan");
		expect(replay).not.toContain("old request");
		expect(replay).not.toContain("old answer");
	});

	test("clips an oversized newest message instead of exceeding the cap", () => {
		const replay = projectReplayContext(
			[u(1, "x".repeat(200))],
			80,
		);

		expect(replay).not.toBeNull();
		expect(replay?.length).toBeLessThanOrEqual(80);
		expect(replay?.startsWith(REPLAY_CONTEXT_TRUNCATED_MARKER)).toBe(true);
		expect(replay).toContain("User:");
	});
});
