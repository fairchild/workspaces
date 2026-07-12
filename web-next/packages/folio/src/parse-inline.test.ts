import { describe, expect, it } from "vitest";
import { parseInline } from "./parse-inline";

describe("parseInline", () => {
	it("passes plain text through", () => {
		expect(parseInline("just prose")).toEqual([
			{ kind: "text", text: "just prose" },
		]);
	});

	it("extracts code spans and emphasis", () => {
		expect(parseInline("the *failing test* calls `resumeSession` twice")).toEqual([
			{ kind: "text", text: "the " },
			{ kind: "em", text: "failing test" },
			{ kind: "text", text: " calls " },
			{ kind: "code", text: "resumeSession" },
			{ kind: "text", text: " twice" },
		]);
	});

	it("handles adjacent and trailing tokens", () => {
		expect(parseInline("`a``b`")).toEqual([
			{ kind: "code", text: "a" },
			{ kind: "code", text: "b" },
		]);
		expect(parseInline("ends with `code`")).toEqual([
			{ kind: "text", text: "ends with " },
			{ kind: "code", text: "code" },
		]);
	});

	it("leaves unbalanced markers alone", () => {
		expect(parseInline("a * b and a ` c")).toEqual([
			{ kind: "text", text: "a * b and a ` c" },
		]);
	});
});
