import { describe, expect, test } from "vitest";
import type { FolioMessage } from "@/components/folio/types";
import {
	applyLiveTurnErrors,
	isVisibleMessage,
	type LiveTurnErrors,
	recordLiveTurnError,
} from "./live-turn-error";

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

describe("recordLiveTurnError (#808)", () => {
	test("records the trailing assistant message's id against the error text", () => {
		const messages = [
			userMessage("u1", "fix the bug"),
			assistantMessage("a1", [], { author: "Claude" }),
		];
		expect(recordLiveTurnError({}, messages, "sandbox died")).toEqual({
			a1: "sandbox died",
		});
	});

	test("normalizes an empty error chunk the same way turn-stats.ts's deriveTurnError does", () => {
		const messages = [assistantMessage("a1")];
		expect(recordLiveTurnError({}, messages, "")).toEqual({
			a1: "The turn failed.",
		});
	});

	test("is idempotent — a message already recorded is returned as the SAME object", () => {
		const current: LiveTurnErrors = { a1: "already recorded" };
		const messages = [assistantMessage("a1")];
		expect(recordLiveTurnError(current, messages, "a different message")).toBe(current);
	});

	test("a no-op when the trailing message isn't an assistant reply", () => {
		const current: LiveTurnErrors = {};
		const messages = [userMessage("u1", "go")];
		expect(recordLiveTurnError(current, messages, "boom")).toBe(current);
	});

	test("a no-op on an empty transcript", () => {
		const current: LiveTurnErrors = {};
		expect(recordLiveTurnError(current, [], "boom")).toBe(current);
	});

	test("accumulates a second, later failure alongside an earlier recorded one", () => {
		const first = recordLiveTurnError({}, [assistantMessage("a1")], "first failure");
		const messages = [
			assistantMessage("a1"),
			userMessage("u2", "try again"),
			assistantMessage("a2"),
		];
		expect(recordLiveTurnError(first, messages, "second failure")).toEqual({
			a1: "first failure",
			a2: "second failure",
		});
	});
});

describe("applyLiveTurnErrors (#808)", () => {
	test("tags every message with a recorded failure, not just the trailing one", () => {
		const messages = [
			userMessage("u1", "fix the bug"),
			assistantMessage("a1", [], { author: "Claude" }),
			userMessage("u2", "try again"),
			assistantMessage("a2", [], { author: "Claude" }),
		];
		const patched = applyLiveTurnErrors(
			messages,
			{ a1: "first failure" },
			"Claude",
		);
		expect(patched[1].metadata?.error).toBe("first failure");
		// a2 — the later, unfailed turn — is untouched.
		expect(patched[3].metadata?.error).toBeUndefined();
		// Messages with no recorded failure are returned as the SAME object.
		expect(patched[0]).toBe(messages[0]);
		expect(patched[3]).toBe(messages[3]);
	});

	test("survives status moving on to a later turn — the earlier card stays tagged (#808 regression)", () => {
		// The scenario codex flagged: turn 1 fails live (no reload), the user
		// retries, and turn 2 succeeds. A status-gated ("only while status ===
		// 'error'") patch would un-tag turn 1's message the instant status
		// leaves "error" for turn 2. The sticky record must not.
		const failures = recordLiveTurnError({}, [assistantMessage("a1")], "sandbox died");
		const messagesAfterRetry = [
			assistantMessage("a1"),
			userMessage("u2", "fix the bug"),
			assistantMessage("a2", [{ type: "text", text: "Fixed it.", state: "done" }], {
				author: "Claude",
			}),
		];
		// status is now "streaming"/"ready" for turn 2, not "error" — a
		// status-gated approach would pass `failures` as empty here.
		const patched = applyLiveTurnErrors(messagesAfterRetry, failures, "Claude");
		expect(patched[0].metadata?.error).toBe("sandbox died");
		expect(patched[2].metadata?.error).toBeUndefined();
	});

	test("preserves whatever partial content the failed message already has", () => {
		const messages = [
			assistantMessage(
				"a1",
				[{ type: "text", text: "Let me check", state: "done" }],
				{ author: "Claude" },
			),
		];
		const patched = applyLiveTurnErrors(messages, { a1: "sandbox died" }, "Claude");
		expect(patched[0].parts).toEqual([
			{ type: "text", text: "Let me check", state: "done" },
		]);
	});

	test("falls back to the given author when the message has no metadata yet", () => {
		const messages = [assistantMessage("a1")];
		const patched = applyLiveTurnErrors(messages, { a1: "boom" }, "Claude");
		expect(patched[0].metadata).toEqual({ author: "Claude", error: "boom" });
	});

	test("does not re-tag a message that already carries an error (e.g. from a reload's projection)", () => {
		const messages = [
			assistantMessage("a1", [], { author: "Claude", error: "already tagged" }),
		];
		const patched = applyLiveTurnErrors(messages, { a1: "a different message" }, "Claude");
		expect(patched[0]).toBe(messages[0]);
	});

	test("returns the SAME array reference when there are no failures recorded", () => {
		const messages = [userMessage("u1", "go")];
		expect(applyLiveTurnErrors(messages, {}, "Claude")).toBe(messages);
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
