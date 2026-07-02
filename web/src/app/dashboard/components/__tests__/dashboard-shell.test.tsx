/**
 * Regression coverage for a real bug: switching repos while the previous
 * repo's `/agents` fetch was still in flight let the stale response win and
 * overwrite the newly-selected repo's data once it resolved late. The fix
 * uses a per-effect `cancelled` flag; this test proves the guard by
 * resolving the *older* repo's fetch *after* the *newer* one, and asserting
 * the newer repo's data is what stays on screen.
 */
import type { AgentDiscoveryResponse } from "@/lib/types";
import { deferred } from "@/test/deferred";
import { installFetchMock, jsonResponse } from "@/test/fetch-mock";
import { act, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DashboardShell } from "../dashboard-shell";

vi.mock("next/navigation", () => ({
	useRouter: () => ({ replace: vi.fn() }),
	usePathname: () => "/dashboard",
	useSearchParams: () => new URLSearchParams(),
}));

// These panels are irrelevant to the repo-switch race and have their own
// fetch/poll behavior — stub them out so the test surface stays scoped to
// DashboardShell's own fetch effect and MainPanel's rendering of it.
vi.mock("../sidebar", () => ({ Sidebar: () => null }));
vi.mock("../chat-panel", () => ({ ChatPanel: () => null }));
vi.mock("../terminal-panel", () => ({ TerminalPanel: () => null }));
vi.mock("../activity-feed", () => ({ ActivityFeed: () => null }));

function agentResponse(name: string): AgentDiscoveryResponse {
	return {
		agents: [
			{ name, role: null, status: "idle", skills: [], lastAction: null },
		],
		skills: [],
		configFiles: [],
		pipeline: { ready: [], claimed: [], review: [], mergeable: [] },
		stats: { agentCount: 1, skillCount: 0, openPRs: 0, readyIssues: 0 },
	};
}

describe("DashboardShell repo-switch race", () => {
	afterEach(() => {
		vi.restoreAllMocks();
	});

	it("keeps the newest repo's data when an older repo's fetch resolves late", async () => {
		const repoADeferred = deferred<AgentDiscoveryResponse>();
		const repoBDeferred = deferred<AgentDiscoveryResponse>();

		const mock = installFetchMock([
			[
				"/api/repos/acme/repo-a/agents",
				() => repoADeferred.promise.then((data) => jsonResponse(data)),
			],
			[
				"/api/repos/acme/repo-b/agents",
				() => repoBDeferred.promise.then((data) => jsonResponse(data)),
			],
			[
				"/webhook-status",
				() => jsonResponse({ connected: false, lastEvent: null }),
			],
			["/api/repos", () => jsonResponse([])],
		]);

		const { rerender } = render(
			<DashboardShell selectedRepo={{ owner: "acme", repo: "repo-a" }} />,
		);

		// Switch repos before repo-a's fetch resolves — this is the race.
		rerender(
			<DashboardShell selectedRepo={{ owner: "acme", repo: "repo-b" }} />,
		);

		// The newer repo's fetch resolves first (plausible: it's the one the
		// user is now waiting on).
		await act(async () => {
			repoBDeferred.resolve(agentResponse("agent-b"));
			await Promise.resolve();
			await Promise.resolve();
		});
		expect(await screen.findByText("agent-b")).not.toBeNull();

		// The stale repo-a fetch resolves after — it must not win.
		await act(async () => {
			repoADeferred.resolve(agentResponse("agent-a"));
			await new Promise((resolve) => setTimeout(resolve, 0));
		});

		expect(screen.queryByText("agent-a")).toBeNull();
		expect(screen.getByText("agent-b")).not.toBeNull();

		mock.restore();
	});
});
