/**
 * Regression coverage for a real bug: MainPanel used to call
 * `useCollapsible` (a hook) after an early return, violating the Rules of
 * Hooks whenever the component re-rendered across the
 * empty-select/loading/error/empty/loaded transitions. React only warns
 * about this ("Rendered more/fewer hooks than during the previous render")
 * rather than throwing in every case, so it's easy to ship silently. This
 * test drives every transition and fails if that warning (or any hook-order
 * warning) reappears.
 */
import type { AgentDiscoveryResponse } from "@/lib/types";
import { jsonResponse } from "@/test/fetch-mock";
import { render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MainPanel } from "../main-panel";

const repo = { owner: "acme", repo: "widgets" };

function loadedData(): AgentDiscoveryResponse {
	return {
		agents: [
			{
				name: "reviewer",
				role: "PR review",
				status: "active",
				skills: ["typescript"],
				lastAction: null,
			},
		],
		skills: [{ name: "typescript", description: "" }],
		configFiles: [],
		pipeline: { ready: [], claimed: [], review: [], mergeable: [] },
		stats: { agentCount: 1, skillCount: 1, openPRs: 0, readyIssues: 0 },
	};
}

describe("MainPanel render transitions", () => {
	let errorSpy: ReturnType<typeof vi.spyOn>;

	beforeEach(() => {
		// WebhookStatus (rendered once agentData is present) fetches its own
		// endpoint; keep it inert so it never touches the assertions below.
		vi.stubGlobal(
			"fetch",
			vi
				.fn()
				.mockResolvedValue(jsonResponse({ connected: false, lastEvent: null })),
		);
		errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
	});

	afterEach(() => {
		errorSpy.mockRestore();
		vi.unstubAllGlobals();
	});

	it("renders every state transition without a hook-order warning", () => {
		const { rerender } = render(
			<MainPanel
				agentData={null}
				selectedRepo={null}
				loading={false}
				error={null}
			/>,
		);
		expect(
			screen.getByText("Select a repo to view agent activity"),
		).not.toBeNull();

		rerender(
			<MainPanel
				agentData={null}
				selectedRepo={repo}
				loading={true}
				error={null}
			/>,
		);

		rerender(
			<MainPanel
				agentData={null}
				selectedRepo={repo}
				loading={false}
				error="Failed to load agent data: boom"
			/>,
		);
		expect(screen.getByText("Failed to load agent data: boom")).not.toBeNull();

		rerender(
			<MainPanel
				agentData={{
					agents: [],
					skills: [],
					configFiles: [],
					pipeline: { ready: [], claimed: [], review: [], mergeable: [] },
					stats: { agentCount: 0, skillCount: 0, openPRs: 0, readyIssues: 0 },
				}}
				selectedRepo={repo}
				loading={false}
				error={null}
			/>,
		);
		expect(screen.getByText("No agent setup detected")).not.toBeNull();

		rerender(
			<MainPanel
				agentData={loadedData()}
				selectedRepo={repo}
				loading={false}
				error={null}
			/>,
		);
		expect(screen.getByText("reviewer")).not.toBeNull();

		const hookOrderWarnings = errorSpy.mock.calls.filter(
			([message]: [unknown]) =>
				typeof message === "string" ? /hooks?/i.test(message) : false,
		);
		expect(hookOrderWarnings).toEqual([]);
		expect(errorSpy).not.toHaveBeenCalled();
	});
});
