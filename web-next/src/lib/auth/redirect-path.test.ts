import { describe, expect, test } from "vitest";
import { safeRedirectPath } from "./redirect-path";

describe("safeRedirectPath", () => {
	test("passes safe relative paths through unchanged", () => {
		for (const path of [
			"/",
			"/sessions/abc-123",
			"/new?repo=fairchild/workspaces",
			"/sessions/x?tab=diff#hunk-2",
		]) {
			expect(safeRedirectPath(path), path).toBe(path);
		}
	});

	test("falls back to / for anything that could leave the origin", () => {
		for (const unsafe of [
			"//evil.com",
			"//evil.com/phish",
			"/\\evil.com",
			"https://evil.com",
			"http://evil.com/",
			"javascript:alert(1)",
			"evil.com",
			"sessions/abc", // relative without leading slash
		]) {
			expect(safeRedirectPath(unsafe), unsafe).toBe("/");
		}
	});

	test("falls back to / when absent or empty", () => {
		expect(safeRedirectPath(null)).toBe("/");
		expect(safeRedirectPath(undefined)).toBe("/");
		expect(safeRedirectPath("")).toBe("/");
	});
});
