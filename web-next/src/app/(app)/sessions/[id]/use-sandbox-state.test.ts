import { describe, expect, test } from "vitest";
import { sandboxStateLabel } from "./use-sandbox-state";

describe("sandboxStateLabel", () => {
	test("renders stopped as a calm resumable resting state", () => {
		expect(sandboxStateLabel({ state: "parked", detail: "stopped" })).toBe(
			"sandbox stopped; resumes next message",
		);
	});

	test("keeps transitional parked states distinct from stopped", () => {
		expect(sandboxStateLabel({ state: "parked", detail: "snapshotting" })).toBe(
			"sandbox parking",
		);
	});
});
