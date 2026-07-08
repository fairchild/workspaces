import { describe, expect, test } from "vitest";
import { needsApproval, type ApprovalPolicy } from "./approval-policy";

describe("needsApproval", () => {
	test.each<ApprovalPolicy>(["auto", "ask-writes", "ask-all"])(
		"classifies auto/ask-all boundaries for %s",
		(policy) => {
			expect(needsApproval(policy, "Edit")).toBe(policy !== "auto");
		},
	);

	test("ask-writes lets read-class tools through", () => {
		for (const tool of ["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch"]) {
			expect(needsApproval("ask-writes", tool)).toBe(false);
		}
	});

	test("ask-writes asks for write-class and unknown tools", () => {
		for (const tool of ["Edit", "Write", "Bash", "NotebookEdit", ""]) {
			expect(needsApproval("ask-writes", tool)).toBe(true);
		}
	});
});
