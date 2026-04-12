import type {
	BetaManagedAgentsAgentMessageEvent,
	BetaManagedAgentsAgentThinkingEvent,
	BetaManagedAgentsAgentToolResultEvent,
	BetaManagedAgentsAgentToolUseEvent,
	BetaManagedAgentsSessionErrorEvent,
	BetaManagedAgentsSessionStatusIdleEvent,
	BetaManagedAgentsStreamSessionEvents,
} from "@anthropic-ai/sdk/resources/beta/sessions/events";
import { afterEach, describe, expect, it } from "vitest";
import { isEndOfTurn, mapEventToChunks } from "../managed-agents-events";

const baseTimestamp = "2026-04-08T00:00:00Z";

function agentMessage(
	id: string,
	text: string,
): BetaManagedAgentsAgentMessageEvent {
	return {
		id,
		type: "agent.message",
		processed_at: baseTimestamp,
		content: [{ type: "text", text }],
	};
}

function thinking(id: string): BetaManagedAgentsAgentThinkingEvent {
	return { id, type: "agent.thinking", processed_at: baseTimestamp };
}

function toolUse(
	id: string,
	name: string,
	input: Record<string, unknown>,
): BetaManagedAgentsAgentToolUseEvent {
	// SDK type includes a few optional fields we don't care about in tests;
	// cast through unknown to avoid restating them.
	return {
		id,
		type: "agent.tool_use",
		processed_at: baseTimestamp,
		name,
		input,
	} as unknown as BetaManagedAgentsAgentToolUseEvent;
}

function toolResult(
	id: string,
	toolUseId: string,
	text: string,
): BetaManagedAgentsAgentToolResultEvent {
	return {
		id,
		type: "agent.tool_result",
		processed_at: baseTimestamp,
		tool_use_id: toolUseId,
		content: [{ type: "text", text }],
	} as unknown as BetaManagedAgentsAgentToolResultEvent;
}

function idle(
	id: string,
	reason: "end_turn" | "requires_action" | "retries_exhausted",
): BetaManagedAgentsSessionStatusIdleEvent {
	if (reason === "requires_action") {
		return {
			id,
			type: "session.status_idle",
			processed_at: baseTimestamp,
			stop_reason: { type: "requires_action", event_ids: [] },
		};
	}
	if (reason === "retries_exhausted") {
		return {
			id,
			type: "session.status_idle",
			processed_at: baseTimestamp,
			stop_reason: {
				type: "retries_exhausted",
			} as unknown as BetaManagedAgentsSessionStatusIdleEvent["stop_reason"],
		};
	}
	return {
		id,
		type: "session.status_idle",
		processed_at: baseTimestamp,
		stop_reason: { type: "end_turn" },
	};
}

function sessionError(
	id: string,
	message: string,
): BetaManagedAgentsSessionErrorEvent {
	return {
		id,
		type: "session.error",
		processed_at: baseTimestamp,
		error: {
			type: "unknown_error",
			message,
		} as unknown as BetaManagedAgentsSessionErrorEvent["error"],
	};
}

describe("mapEventToChunks", () => {
	afterEach(() => {
		Reflect.deleteProperty(process.env, "MANAGED_AGENTS_SHOW_THINKING");
	});

	it("maps agent.message text blocks to text chunks", () => {
		const chunks = mapEventToChunks(agentMessage("evt_1", "hello world"));
		expect(chunks).toEqual([{ type: "text", content: "hello world" }]);
	});

	it("emits one chunk per text block in a multi-block message", () => {
		const event: BetaManagedAgentsAgentMessageEvent = {
			id: "evt_2",
			type: "agent.message",
			processed_at: baseTimestamp,
			content: [
				{ type: "text", text: "part one " },
				{ type: "text", text: "part two" },
			],
		};
		const chunks = mapEventToChunks(event);
		expect(chunks.map((c) => c.content).join("")).toBe("part one part two");
		expect(chunks).toHaveLength(2);
	});

	it("skips agent.thinking by default", () => {
		expect(mapEventToChunks(thinking("evt_3"))).toEqual([]);
	});

	it("surfaces agent.thinking when MANAGED_AGENTS_SHOW_THINKING=1", () => {
		process.env.MANAGED_AGENTS_SHOW_THINKING = "1";
		const chunks = mapEventToChunks(thinking("evt_4"));
		expect(chunks).toEqual([{ type: "status", content: "thinking" }]);
	});

	it("emits tool_use chunks with input metadata", () => {
		const chunks = mapEventToChunks(
			toolUse("evt_5", "bash", { command: "ls -la" }),
		);
		expect(chunks).toHaveLength(1);
		expect(chunks[0].type).toBe("tool_use");
		expect(chunks[0].content).toBe("bash");
		expect(chunks[0].metadata).toMatchObject({
			id: "evt_5",
			input: { command: "ls -la" },
		});
	});

	it("emits tool_result chunks only when the result has text content", () => {
		const withText = mapEventToChunks(toolResult("evt_6", "evt_5", "total 0"));
		expect(withText).toEqual([
			{
				type: "tool_result",
				content: "total 0",
				metadata: { tool_use_id: "evt_5" },
			},
		]);

		const empty = mapEventToChunks({
			id: "evt_7",
			type: "agent.tool_result",
			processed_at: baseTimestamp,
			tool_use_id: "evt_5",
			content: [],
		} as unknown as BetaManagedAgentsAgentToolResultEvent);
		expect(empty).toEqual([]);
	});

	it("maps end-of-turn session.status_idle to a done chunk", () => {
		const chunks = mapEventToChunks(idle("evt_8", "end_turn"));
		expect(chunks).toEqual([{ type: "done", content: "" }]);
		expect(isEndOfTurn(idle("evt_8", "end_turn"))).toBe(true);
	});

	it("treats retries_exhausted as end-of-turn", () => {
		expect(isEndOfTurn(idle("evt_9", "retries_exhausted"))).toBe(true);
	});

	it("does NOT treat requires_action as end-of-turn", () => {
		expect(isEndOfTurn(idle("evt_10", "requires_action"))).toBe(false);
		expect(mapEventToChunks(idle("evt_10", "requires_action"))).toEqual([]);
	});

	it("maps session.error to an error chunk", () => {
		const chunks = mapEventToChunks(sessionError("evt_11", "rate limited"));
		expect(chunks).toEqual([{ type: "error", content: "rate limited" }]);
	});

	it("ignores unknown event types without throwing", () => {
		const weird = {
			id: "evt_12",
			type: "span.outcome_evaluation_start",
			processed_at: baseTimestamp,
		} as unknown as BetaManagedAgentsStreamSessionEvents;
		expect(() => mapEventToChunks(weird)).not.toThrow();
		expect(mapEventToChunks(weird)).toEqual([]);
	});
});
