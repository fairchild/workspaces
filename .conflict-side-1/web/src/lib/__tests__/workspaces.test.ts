import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Workspace } from "../types";
import { formatWorkspaceStatusCard, relativeTime } from "../workspaces";

// Pin time for deterministic relative time tests
const NOW = new Date("2026-03-29T12:00:00Z");

beforeEach(() => {
	vi.useFakeTimers();
	vi.setSystemTime(NOW);
});

afterEach(() => {
	vi.useRealTimers();
});

describe("relativeTime", () => {
	it("returns 'just now' for < 1 minute", () => {
		expect(relativeTime("2026-03-29T11:59:30Z")).toBe("just now");
	});

	it("returns minutes for < 1 hour", () => {
		expect(relativeTime("2026-03-29T11:55:00Z")).toBe("5m ago");
	});

	it("returns hours for < 1 day", () => {
		expect(relativeTime("2026-03-29T09:00:00Z")).toBe("3h ago");
	});

	it("returns days for >= 1 day", () => {
		expect(relativeTime("2026-03-27T12:00:00Z")).toBe("2d ago");
	});
});

function makeWorkspace(overrides: Partial<Workspace> = {}): Workspace {
	return {
		id: "ws-1",
		name: "my-project",
		path: "/Users/dev/project",
		repoId: null,
		repoName: null,
		createdAt: "2026-03-01T00:00:00Z",
		lastAccessedAt: "2026-03-29T11:55:00Z",
		status: "active",
		gitBranch: "main",
		backendIdentifier: "local",
		...overrides,
	};
}

describe("formatWorkspaceStatusCard", () => {
	it("returns placeholder for empty array", () => {
		expect(formatWorkspaceStatusCard([])).toBe("No workspaces tracked yet.");
	});

	it("formats single workspace as markdown table", () => {
		const result = formatWorkspaceStatusCard([makeWorkspace()]);
		expect(result).toContain("**Workspace Status**");
		expect(result).toContain("| Workspace | Status | Branch | Last Activity |");
		expect(result).toContain("| my-project |");
		expect(result).toContain("active");
		expect(result).toContain("`main`");
	});

	it("shows correct emoji for each status", () => {
		const statuses = [
			{ status: "active" as const, emoji: "\u{1F7E2}" },
			{ status: "provisioning" as const, emoji: "\u{1F7E1}" },
			{ status: "stopped" as const, emoji: "\u{1F534}" },
			{ status: "archived" as const, emoji: "\u26AA" },
		];
		for (const { status, emoji } of statuses) {
			const result = formatWorkspaceStatusCard([makeWorkspace({ status })]);
			expect(result).toContain(`${emoji} ${status}`);
		}
	});

	it("shows dash when gitBranch is null", () => {
		const result = formatWorkspaceStatusCard([
			makeWorkspace({ gitBranch: null }),
		]);
		expect(result).toContain("`\u2014`");
	});

	it("formats multiple workspaces", () => {
		const result = formatWorkspaceStatusCard([
			makeWorkspace({ name: "project-a" }),
			makeWorkspace({ name: "project-b", id: "ws-2" }),
		]);
		expect(result).toContain("| project-a |");
		expect(result).toContain("| project-b |");
	});
});
