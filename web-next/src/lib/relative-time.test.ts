import { describe, expect, test } from "vitest";
import { formatRelativeTime } from "./relative-time";

const NOW = new Date("2026-07-03T12:00:00.000Z");

describe("formatRelativeTime", () => {
	test.each([
		["2026-07-03T11:59:30.000Z", "just now"],
		["2026-07-03T11:56:00.000Z", "4m ago"],
		["2026-07-03T09:00:00.000Z", "3h ago"],
		["2026-07-01T12:00:00.000Z", "2d ago"],
		["2026-06-12T12:00:00.000Z", "Jun 12"],
		["2025-12-31T12:00:00.000Z", "Dec 31 2025"],
	])("%s → %s", (iso, expected) => {
		expect(formatRelativeTime(iso, NOW)).toBe(expected);
	});

	test("unparseable input renders as nothing rather than NaN", () => {
		expect(formatRelativeTime("not-a-date", NOW)).toBe("");
	});
});
