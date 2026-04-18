import { TYPE_COLOR, TYPE_LABEL } from "@/app/dashboard/components/event-utils";
import { describe, expect, it } from "vitest";

describe("event-utils", () => {
	it("keeps webhook labels stable", () => {
		expect(TYPE_LABEL.pull_request).toBe("PR");
		expect(TYPE_LABEL.workflow_run).toBe("CI");
		expect(TYPE_LABEL.discussion_comment).toBe("DISC");
		expect(TYPE_LABEL.issue_comment).toBe("ISSUE");
	});

	it("maps webhook types to the shared color keys", () => {
		expect(TYPE_COLOR.pull_request).toBe("pr");
		expect(TYPE_COLOR.check_run).toBe("ci");
		expect(TYPE_COLOR.push).toBe("push");
		expect(TYPE_COLOR.discussion).toBe("discussion");
		expect(TYPE_COLOR.issues).toBe("issue");
	});
});
