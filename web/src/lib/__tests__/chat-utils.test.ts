import { describe, expect, it } from "vitest";
import {
	formatDispatchBody,
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

describe("bot command routing (TODO)", () => {
	it.todo("@spaces status returns workspace status table");
	it.todo("@spaces pipeline returns pipeline info message");
	it.todo("@agent status returns agent status placeholder");
	it.todo("unknown @spaces command falls through to Discussion dispatch");
	it.todo("@agent with task body dispatches to GitHub Discussion");
});
