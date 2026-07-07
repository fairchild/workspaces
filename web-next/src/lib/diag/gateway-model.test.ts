import { describe, expect, test } from "vitest";
import { MODEL_OPTIONS } from "@/lib/agent-runtime/models";
import { resolveGatewayModel, toGatewayModelId } from "./gateway-model";

describe("toGatewayModelId", () => {
	test("translates every current selectable model id (grounded against the pre-existing hardcoded call)", () => {
		expect(toGatewayModelId("claude-fable-5")).toBe("anthropic/claude-fable-5");
		expect(toGatewayModelId("claude-opus-4-8")).toBe("anthropic/claude-opus-4.8");
		expect(toGatewayModelId("claude-sonnet-5")).toBe("anthropic/claude-sonnet-5");
		expect(toGatewayModelId("claude-haiku-4-5")).toBe("anthropic/claude-haiku-4.5");
	});

	test("every MODEL_OPTIONS id translates to a distinct gateway id", () => {
		const translated = MODEL_OPTIONS.map((option) => toGatewayModelId(option.id));
		expect(new Set(translated).size).toBe(MODEL_OPTIONS.length);
	});
});

describe("resolveGatewayModel", () => {
	test("accepts a known id and returns its gateway translation", () => {
		expect(resolveGatewayModel("claude-haiku-4-5")).toEqual({
			ok: true,
			gatewayModel: "anthropic/claude-haiku-4.5",
		});
	});

	test("rejects an id outside the selectable set", () => {
		expect(resolveGatewayModel("gpt-5")).toEqual({
			ok: false,
			error: "unknown model: gpt-5",
		});
	});

	test("rejects the empty string", () => {
		expect(resolveGatewayModel("").ok).toBe(false);
	});
});
