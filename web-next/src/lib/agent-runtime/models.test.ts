import { describe, expect, test } from "vitest";
import { DEFAULT_MODEL, isSelectableModel, MODEL_OPTIONS, modelLabel } from "./models";

describe("models", () => {
	test("the default model is one of the selectable options", () => {
		expect(MODEL_OPTIONS.some((option) => option.id === DEFAULT_MODEL)).toBe(true);
	});

	test("every option has a unique id and a non-empty label", () => {
		const ids = MODEL_OPTIONS.map((option) => option.id);
		expect(new Set(ids).size).toBe(ids.length);
		for (const option of MODEL_OPTIONS) {
			expect(option.label.length).toBeGreaterThan(0);
		}
	});

	test("isSelectableModel accepts known ids and rejects everything else", () => {
		expect(isSelectableModel(DEFAULT_MODEL)).toBe(true);
		expect(isSelectableModel("claude-opus-4-8")).toBe(true);
		expect(isSelectableModel("gpt-5")).toBe(false);
		expect(isSelectableModel("")).toBe(false);
	});

	test("modelLabel resolves known ids and falls back to the raw id otherwise", () => {
		expect(modelLabel("claude-haiku-4-5")).toBe("Haiku 4.5");
		expect(modelLabel("some-retired-model")).toBe("some-retired-model");
	});
});
