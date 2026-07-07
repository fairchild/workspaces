import { describe, expect, test } from "vitest";
import {
	buildDeployedResults,
	DEPLOYED_SKIP_REASON,
	deployedResultsToMarkdown,
	skipScenariosForDeployedTarget,
} from "./deployed-core.mjs";

const contract = {
	scenarios: [
		{ id: "ttft_mock" },
		{ id: "route_home" },
	],
};

describe("skipScenariosForDeployedTarget", () => {
	test("every contract scenario is reported skipped with the same reason", () => {
		const skips = skipScenariosForDeployedTarget(contract);
		expect(skips).toEqual([
			{ id: "ttft_mock", status: "skipped", reason: DEPLOYED_SKIP_REASON },
			{ id: "route_home", status: "skipped", reason: DEPLOYED_SKIP_REASON },
		]);
	});

	test("never silently drops a scenario", () => {
		expect(skipScenariosForDeployedTarget(contract)).toHaveLength(contract.scenarios.length);
	});
});

describe("buildDeployedResults", () => {
	const target = { envName: "prod", baseUrl: "https://example.vercel.app" };
	const entry = {
		id: "deployed_entry_signin",
		status: "measured",
		route: "/sign-in",
		metrics: { lcp_ms: { value: 210 }, tbt_ms: { value: 0 } },
	};

	test("includes the contract skips, the entry measurement, and is marked report-only", () => {
		const results = buildDeployedResults({ target, commit: "abc123", contract, entry });
		expect(results.mode).toBe("deployed");
		expect(results.target).toEqual(target);
		expect(results.commit).toBe("abc123");
		expect(results.note).toMatch(/report-only/i);
		expect(results.scenarios).toHaveLength(contract.scenarios.length + 1);
		expect(results.scenarios.at(-1)).toBe(entry);
	});

	test("passes through an entry that is itself a skip (e.g. an SSO wall)", () => {
		const walledEntry = {
			id: "deployed_entry_signin",
			status: "skipped",
			reason: "Vercel deployment protection (SSO) — set VERCEL_AUTOMATION_BYPASS_SECRET (#814)",
		};
		const results = buildDeployedResults({ target, commit: "abc123", contract, entry: walledEntry });
		expect(results.scenarios.at(-1)).toBe(walledEntry);
	});
});

describe("deployedResultsToMarkdown", () => {
	test("renders skip lines and measured metric lines", () => {
		const results = buildDeployedResults({
			target: { envName: "prod", baseUrl: "https://example.vercel.app" },
			commit: "abc123",
			contract,
			entry: {
				id: "deployed_entry_signin",
				status: "measured",
				metrics: { lcp_ms: { value: 210 }, tbt_ms: { value: 0 } },
			},
		});
		const md = deployedResultsToMarkdown(results);
		expect(md).toContain("report-only");
		expect(md).toContain("| ttft_mock | — | — | skipped");
		expect(md).toContain("| deployed_entry_signin | lcp_ms | 210 | measured (report-only) |");
		expect(md).toContain("| deployed_entry_signin | tbt_ms | 0 | measured (report-only) |");
	});

	test("renders a skipped entry (SSO wall) as a skip line, not a crash", () => {
		const results = buildDeployedResults({
			target: { envName: "prod", baseUrl: "https://example.vercel.app" },
			commit: "abc123",
			contract,
			entry: { id: "deployed_entry_signin", status: "skipped", reason: "walled" },
		});
		const md = deployedResultsToMarkdown(results);
		expect(md).toContain("| deployed_entry_signin | — | — | skipped (walled) |");
	});
});
