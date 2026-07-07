import { describe, expect, test } from "vitest";
import { cleanTitleText, deriveSessionTitle, MAX_TITLE_LENGTH } from "./session-title";

describe("deriveSessionTitle", () => {
	test("cleans and returns the first line", () => {
		expect(deriveSessionTitle("Fix the login bug")).toBe("Fix the login bug");
	});

	test("trims and collapses internal whitespace", () => {
		expect(deriveSessionTitle("  Fix   the   login   bug  \nmore detail")).toBe(
			"Fix the login bug",
		);
	});

	test("caps at MAX_TITLE_LENGTH with an ellipsis", () => {
		const long = "x".repeat(MAX_TITLE_LENGTH + 40);
		const title = deriveSessionTitle(long);
		expect(title.length).toBe(MAX_TITLE_LENGTH);
		expect(title.endsWith("…")).toBe(true);
		expect(title.startsWith("x".repeat(MAX_TITLE_LENGTH - 1))).toBe(true);
	});

	test("does not cap a message exactly at the limit", () => {
		const exact = "x".repeat(MAX_TITLE_LENGTH);
		expect(deriveSessionTitle(exact)).toBe(exact);
	});

	test("returns empty for an empty or whitespace-only message", () => {
		expect(deriveSessionTitle("")).toBe("");
		expect(deriveSessionTitle("   \t  ")).toBe("");
		expect(deriveSessionTitle("\n\nsecond line has content")).toBe("");
	});
});

describe("cleanTitleText", () => {
	test("trims edges and collapses interior whitespace", () => {
		expect(cleanTitleText("  hello   world  ")).toBe("hello world");
	});

	test("collapses newlines and tabs into single spaces", () => {
		expect(cleanTitleText("hello\n\tworld")).toBe("hello world");
	});
});
