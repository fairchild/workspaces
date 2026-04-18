import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { formatRelativeTime } from "../timeline-utils";
import type { Workspace } from "../types";
import {
	type SyncWorkspaceInput,
	formatWorkspaceStatusCard,
	getWorkspaces,
	syncWorkspaces,
} from "../workspaces";

// Pin time for deterministic relative time tests
const NOW = new Date("2026-03-29T12:00:00Z");

beforeEach(() => {
	vi.useFakeTimers();
	vi.setSystemTime(NOW);
});

afterEach(() => {
	vi.useRealTimers();
});

describe("formatRelativeTime", () => {
	it("returns 'just now' for < 1 minute", () => {
		expect(formatRelativeTime("2026-03-29T11:59:30Z")).toBe("just now");
	});

	it("returns minutes for < 1 hour", () => {
		expect(formatRelativeTime("2026-03-29T11:55:00Z")).toBe("5m ago");
	});

	it("returns hours for < 1 day", () => {
		expect(formatRelativeTime("2026-03-29T09:00:00Z")).toBe("3h ago");
	});

	it("returns days for >= 1 day", () => {
		expect(formatRelativeTime("2026-03-27T12:00:00Z")).toBe("2d ago");
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

describe("syncWorkspaces (parallel upserts)", () => {
	// No fake timers — these tests exercise real DB writes and need real time
	beforeEach(() => {
		vi.useRealTimers();
	});

	function makeInput(
		id: string,
		overrides: Partial<SyncWorkspaceInput> = {},
	): SyncWorkspaceInput {
		return {
			id,
			name: id,
			path: `/tmp/${id}`,
			createdAt: new Date().toISOString(),
			lastAccessedAt: new Date().toISOString(),
			status: "active",
			backendIdentifier: "local",
			...overrides,
		};
	}

	it("persists every row in a multi-entry batch", async () => {
		const prefix = `batch-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
		const inputs = Array.from({ length: 20 }, (_, i) =>
			makeInput(`${prefix}-${i}`, { repoName: `acme/repo-${i}` }),
		);

		const count = await syncWorkspaces(inputs);
		expect(count).toBe(20);

		// Pull each back individually to avoid accidentally matching rows from
		// other tests in the shared DB.
		const all = await getWorkspaces();
		const ours = all.filter((w) => w.id.startsWith(prefix));
		expect(ours).toHaveLength(20);
	});

	it("upserts existing rows with new field values", async () => {
		const id = `upsert-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
		await syncWorkspaces([makeInput(id, { status: "active" })]);
		await syncWorkspaces([makeInput(id, { status: "stopped" })]);

		const all = await getWorkspaces();
		const ours = all.filter((w) => w.id === id);
		expect(ours).toHaveLength(1);
		expect(ours[0].status).toBe("stopped");
	});
});
