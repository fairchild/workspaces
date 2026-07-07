/*
 * Pure logic for perf/run.mjs's deployed-target mode (#856): every
 * contract.json scenario needs the auth-bypass cookie plus locally seeded
 * fixtures (contract.json's "auth" methodology note), neither of which
 * exists against a real deployment, so each is reported skipped rather than
 * silently omitted or budget-failed. The one honest, credential-free
 * measurement against a live deployment is the /sign-in entry route's
 * LCP/TBT — reachable by anyone, gates nothing. No I/O here; perf/run.mjs
 * does the actual probing and browser work (mirrors the
 * scripts/validate-core.mjs / validate-core.test.mjs split).
 */

export const DEPLOYED_SKIP_REASON =
	"requires the auth-bypass cookie + locally seeded fixtures — not available against a deployed target";

/** Every contract scenario is auth-gated and/or fixture-seeded; report each skipped by name rather than omitting them. */
export function skipScenariosForDeployedTarget(contract) {
	return contract.scenarios.map((scenario) => ({
		id: scenario.id,
		status: "skipped",
		reason: DEPLOYED_SKIP_REASON,
	}));
}

/**
 * Assembles the deployed-mode report: the contract scenario skips plus the
 * one honest entry-route measurement (itself possibly a skip, e.g. behind an
 * SSO wall). Deployed-target results are report-only — nothing here ever
 * fails a budget; see docs/perf-floor.md.
 */
export function buildDeployedResults({ target, commit, contract, entry }) {
	return {
		mode: "deployed",
		target: { envName: target.envName, baseUrl: target.baseUrl },
		date: new Date().toISOString(),
		commit,
		note: "Deployed-target results are report-only: no budget gates a deployed run. See docs/perf-floor.md.",
		scenarios: [...skipScenariosForDeployedTarget(contract), entry],
	};
}

/** Renders the deployed report the same shape as the local run's markdown table, plus skip lines. */
export function deployedResultsToMarkdown(results) {
	const lines = [
		`Deployed-target report (report-only, no budget gate): ${results.target.envName} — ${results.target.baseUrl}`,
		"",
		"| Scenario | Metric | Value | Status |",
		"|---|---|---|---|",
	];
	for (const scenario of results.scenarios) {
		if (scenario.status === "skipped") {
			lines.push(`| ${scenario.id} | — | — | skipped (${scenario.reason}) |`);
			continue;
		}
		for (const [name, metric] of Object.entries(scenario.metrics ?? {})) {
			lines.push(`| ${scenario.id} | ${name} | ${metric.value} | measured (report-only) |`);
		}
	}
	return lines.join("\n");
}
