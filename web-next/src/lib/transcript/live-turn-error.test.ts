import { describe, expect, test } from "vitest";
import type { FolioMessage } from "@/components/folio/types";
import { isVisibleMessage, withLiveTurnError } from "./live-turn-error";

function userMessage(id: string, text: string): FolioMessage {
	return { id, role: "user", parts: [{ type: "text", text, state: "done" }] };
}

function assistantMessage(
	id: string,
	parts: FolioMessage["parts"] = [],
	metadata?: FolioMessage["metadata"],
): FolioMessage {
	return { id, role: "assistant", parts, metadata };
}

describe("withLiveTurnError (#808)", () => {
	test("tags the trailing empty assistant placeholder with the failure", () => {
		const messages = [
			userMessage("u1", "fix the bug"),
			assistantMessage("a1", [], { author: "Claude" }),
		];
		const patched = withLiveTurnError(messages, "sandbox died", "Claude");
		expect(patched[1]).toMatchObject({
			id: "a1",
			role: "assistant",
			metadata: { author: "Claude", error: "sandbox died" },
		});
		// The user's turn text is untouched — it was never at risk (already
		// durably persisted before the assistant turn even starts).
		expect(patched[0]).toEqual(messages[0]);
	});

	test("preserves whatever partial content the trailing message already has", () => {
		const messages = [
			userMessage("u1", "fix the bug"),
			assistantMessage(
				"a1",
				[{ type: "text", text: "Let me check", state: "done" }],
				{ author: "Claude" },
			),
		];
		const patched = withLiveTurnError(messages, "sandbox died", "Claude");
		expect(patched[1].parts).toEqual([
			{ type: "text", text: "Let me check", state: "done" },
		]);
		expect(patched[1].metadata?.error).toBe("sandbox died");
	});

	test("falls back to the given author when the message has no metadata yet", () => {
		const messages = [userMessage("u1", "go"), assistantMessage("a1")];
		const patched = withLiveTurnError(messages, "boom", "Claude");
		expect(patched[1].metadata).toEqual({ author: "Claude", error: "boom" });
	});

	test("is idempotent — a message that already carries an error is returned unchanged", () => {
		const messages = [
			userMessage("u1", "go"),
			assistantMessage("a1", [], { author: "Claude", error: "already tagged" }),
		];
		const patched = withLiveTurnError(messages, "a different message", "Claude");
		expect(patched).toBe(messages);
	});

	test("a no-op when the trailing message isn't an assistant reply", () => {
		const messages = [userMessage("u1", "go")];
		expect(withLiveTurnError(messages, "boom", "Claude")).toBe(messages);
	});

	test("a no-op on an empty transcript", () => {
		expect(withLiveTurnError([], "boom", "Claude")).toEqual([]);
	});
});

describe("isVisibleMessage (#808)", () => {
	test("a message with parts is visible", () => {
		expect(
			isVisibleMessage(
				assistantMessage("a1", [{ type: "text", text: "hi", state: "done" }]),
			),
		).toBe(true);
	});

	test("a failed turn with no parts is still visible", () => {
		expect(
			isVisibleMessage(assistantMessage("a1", [], { author: "Claude", error: "boom" })),
		).toBe(true);
	});

	test("an empty in-progress placeholder (no parts, no error) is hidden", () => {
		expect(isVisibleMessage(assistantMessage("a1", [], { author: "Claude" }))).toBe(
			false,
		);
	});
});
