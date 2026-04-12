import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { dayKey, shouldShowDay } from "../timeline-utils";
import type { TimelineEntry } from "../types";

function chatEntry(timestamp: string): TimelineEntry {
	return {
		kind: "chat",
		id: `msg-${timestamp}`,
		repo: "owner/repo",
		author: "user",
		authorType: "user",
		content: "hello",
		agentTarget: null,
		discussionId: null,
		discussionUrl: null,
		timestamp,
	};
}

describe("dayKey", () => {
	it("formats ISO timestamp to month + day", () => {
		const key = dayKey("2026-03-29T20:00:00Z");
		// Verify format is "Mon DD" (locale-dependent on timezone but always short month + day)
		expect(key).toMatch(/^[A-Z][a-z]{2} \d{1,2}$/);
	});

	it("returns same key for same-day timestamps", () => {
		// Use mid-day times to avoid timezone boundary issues
		const a = dayKey("2026-03-29T18:00:00Z");
		const b = dayKey("2026-03-29T20:00:00Z");
		expect(a).toBe(b);
	});

	it("returns different keys for different days", () => {
		// Use times far apart to guarantee different local days
		const a = dayKey("2026-03-27T20:00:00Z");
		const b = dayKey("2026-03-29T20:00:00Z");
		expect(a).not.toBe(b);
	});
});

describe("shouldShowDay", () => {
	it("returns true for first entry", () => {
		const entries = [chatEntry("2026-03-29T20:00:00Z")];
		expect(shouldShowDay(entries, 0)).toBe(true);
	});

	it("returns false for same day as previous", () => {
		const entries = [
			chatEntry("2026-03-29T18:00:00Z"),
			chatEntry("2026-03-29T20:00:00Z"),
		];
		expect(shouldShowDay(entries, 1)).toBe(false);
	});

	it("returns true when day changes", () => {
		// 2 days apart to avoid timezone edge cases
		const entries = [
			chatEntry("2026-03-27T20:00:00Z"),
			chatEntry("2026-03-29T20:00:00Z"),
		];
		expect(shouldShowDay(entries, 1)).toBe(true);
	});
});
