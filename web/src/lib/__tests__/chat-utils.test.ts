import { describe, expect, it, vi } from "vitest";
import {
	type EventStats,
	formatDispatchBody,
	handleBotCommand,
	parseAgentMention,
	parseIssueRef,
	stripMention,
} from "../chat-utils";

describe("parseAgentMention", () => {
	it("extracts agent name from start of message", () => {
		expect(parseAgentMention("@agent-1 do something")).toBe("agent-1");
	});

	it("extracts single-word agent name", () => {
		expect(parseAgentMention("@spaces status")).toBe("spaces");
	});

	it("handles underscores in agent name", () => {
		expect(parseAgentMention("@my_agent task")).toBe("my_agent");
	});

	it("returns null when mention is not at start", () => {
		expect(parseAgentMention("hello @agent")).toBeNull();
	});

	it("returns null for empty string", () => {
		expect(parseAgentMention("")).toBeNull();
	});

	it("returns null for text without mention", () => {
		expect(parseAgentMention("no mention here")).toBeNull();
	});
});

describe("stripMention", () => {
	it("removes mention and trims", () => {
		expect(stripMention("@agent-1 do something")).toBe("do something");
	});

	it("returns empty string when only mention", () => {
		expect(stripMention("@agent")).toBe("");
	});

	it("handles extra whitespace after mention", () => {
		expect(stripMention("@spaces   status")).toBe("status");
	});

	it("returns unchanged text without mention", () => {
		expect(stripMention("no mention")).toBe("no mention");
	});
});

describe("parseIssueRef", () => {
	it("extracts issue number", () => {
		expect(parseIssueRef("fix bug #42")).toBe("#42");
	});

	it("returns first match when multiple present", () => {
		expect(parseIssueRef("fix #123 and #456")).toBe("#123");
	});

	it("extracts issue at start", () => {
		expect(parseIssueRef("#7 needs fixing")).toBe("#7");
	});

	it("returns null when no issue ref", () => {
		expect(parseIssueRef("no issue ref")).toBeNull();
	});
});

describe("formatDispatchBody", () => {
	it("formats body with issue ref", () => {
		const body = formatDispatchBody("april", "fix the bug", "#42", "abc12345");
		expect(body).toContain("**Agent:** @april");
		expect(body).toContain("**Task:** fix the bug");
		expect(body).toContain("**Task ID:** `abc12345`");
		expect(body).toContain("**Issue:** #42");
		expect(body).toContain("*Dispatched from [Spaces]");
	});

	it("omits issue line when issueRef is null", () => {
		const body = formatDispatchBody("bot", "do work", null, "xyz99999");
		expect(body).not.toContain("**Issue:**");
		expect(body).toContain("**Agent:** @bot");
		expect(body).toContain("**Task ID:** `xyz99999`");
	});

	it("includes footer with link", () => {
		const body = formatDispatchBody("a", "b", null, "c");
		expect(body).toContain("https://spaces.cloudcompute.com");
	});
});

describe("handleBotCommand", () => {
	const mockStats: EventStats = {
		eventsToday: 12,
		repos: ["fairchild/workspaces", "fairchild/dotclaude"],
	};

	function makeParams(target: string | null, message: string) {
		return {
			target,
			message,
			repo: "fairchild/workspaces",
			author: "testuser",
			getEventStats: vi
				.fn<() => Promise<EventStats>>()
				.mockResolvedValue(mockStats),
			pushChatMessage: vi.fn().mockResolvedValue(undefined),
		};
	}

	it("@spaces status returns repo list and event count", async () => {
		const params = makeParams("spaces", "@spaces status");
		const result = await handleBotCommand(params);
		expect(result).not.toBeNull();
		expect(params.getEventStats).toHaveBeenCalledOnce();
		expect(params.pushChatMessage).toHaveBeenCalledTimes(2);
		const botMsg = params.pushChatMessage.mock.calls[1][0];
		expect(botMsg.content).toContain("fairchild/workspaces");
		expect(botMsg.content).toContain("12");
		expect(botMsg.authorType).toBe("bot");
	});

	it("@spaces pipeline returns pipeline message", async () => {
		const params = makeParams("spaces", "@spaces pipeline");
		const result = await handleBotCommand(params);
		expect(result).not.toBeNull();
		expect(params.getEventStats).not.toHaveBeenCalled();
		expect(params.pushChatMessage).toHaveBeenCalledTimes(2);
		const botMsg = params.pushChatMessage.mock.calls[1][0];
		expect(botMsg.content).toContain("Dashboard tab");
	});

	it("@agent status returns agent status placeholder", async () => {
		const params = makeParams("april", "@april status");
		const result = await handleBotCommand(params);
		expect(result).not.toBeNull();
		expect(params.pushChatMessage).toHaveBeenCalledTimes(2);
		const botMsg = params.pushChatMessage.mock.calls[1][0];
		expect(botMsg.content).toContain("@april");
		expect(botMsg.content).toContain("No active dispatches");
	});

	it("unknown @spaces command returns null", async () => {
		const params = makeParams("spaces", "@spaces unknown-cmd");
		const result = await handleBotCommand(params);
		expect(result).toBeNull();
		expect(params.pushChatMessage).not.toHaveBeenCalled();
	});

	it("@agent with task body returns null (falls through to dispatch)", async () => {
		const params = makeParams("april", "@april fix the bug in auth");
		const result = await handleBotCommand(params);
		expect(result).toBeNull();
		expect(params.pushChatMessage).not.toHaveBeenCalled();
	});

	it("returns null when target is null", async () => {
		const params = makeParams(null, "hello world");
		const result = await handleBotCommand(params);
		expect(result).toBeNull();
	});
});
