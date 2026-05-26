import { describe, expect, it, vi } from "vitest";
import {
	findForbiddenPublicAgentMention,
	formatDispatchBody,
	handleBotCommand,
	parseAgentMention,
	parseIssueRef,
	stripMention,
	validatePublicAgentTarget,
} from "../chat-utils";
import type { EventStats } from "../events";

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

describe("validatePublicAgentTarget", () => {
	it("allows canonical April Clearwater public target", () => {
		expect(validatePublicAgentTarget("april-clearwater")).toBeNull();
	});

	it("rejects the short April alias because it is a real GitHub user", () => {
		expect(validatePublicAgentTarget("april")).toContain(
			"Use @april-clearwater instead of @april",
		);
	});

	it("rejects malformed target names before they become GitHub mentions", () => {
		expect(validatePublicAgentTarget("octo/agent")).toContain(
			"Agent names may contain only",
		);
	});

	it("can reject spaces where an agent target is required", () => {
		expect(validatePublicAgentTarget("spaces")).toBeNull();
		expect(
			validatePublicAgentTarget("spaces", { allowSpaces: false }),
		).toContain("not a dispatchable agent");
	});
});

describe("findForbiddenPublicAgentMention", () => {
	it("finds @april in GitHub-bound text", () => {
		expect(findForbiddenPublicAgentMention("@april please handle this")).toBe(
			"@april",
		);
		expect(findForbiddenPublicAgentMention("please ask @april")).toBe("@april");
	});

	it("does not flag canonical April Clearwater or longer names", () => {
		expect(
			findForbiddenPublicAgentMention("@april-clearwater status"),
		).toBeNull();
		expect(findForbiddenPublicAgentMention("@april_extra status")).toBeNull();
		expect(
			findForbiddenPublicAgentMention("@april-clearwater-extra"),
		).toBeNull();
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
		const body = formatDispatchBody(
			"april-clearwater",
			"fix the bug",
			"#42",
			"abc12345",
		);
		expect(body).toContain("**Agent:** @april-clearwater");
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
		const params = makeParams("april-clearwater", "@april-clearwater status");
		const result = await handleBotCommand(params);
		expect(result).not.toBeNull();
		expect(params.pushChatMessage).toHaveBeenCalledTimes(2);
		const botMsg = params.pushChatMessage.mock.calls[1][0];
		expect(botMsg.content).toContain("@april-clearwater");
		expect(botMsg.content).toContain("No active dispatches");
	});

	it("unknown @spaces command returns null", async () => {
		const params = makeParams("spaces", "@spaces unknown-cmd");
		const result = await handleBotCommand(params);
		expect(result).toBeNull();
		expect(params.pushChatMessage).not.toHaveBeenCalled();
	});

	it("@agent with task body returns null (falls through to dispatch)", async () => {
		const params = makeParams(
			"april-clearwater",
			"@april-clearwater fix the bug in auth",
		);
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
