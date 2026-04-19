#!/usr/bin/env node
import { readFileSync } from "node:fs";

const reportPath = process.argv[2];
if (!reportPath) {
	console.error("usage: playwright-findings.js <playwright-report.json>");
	process.exit(2);
}

const report = JSON.parse(readFileSync(reportPath, "utf8"));

const failures = [];
function walk(suite, trail) {
	const here = trail.concat(suite.title ? [suite.title] : []);
	for (const spec of suite.specs ?? []) {
		for (const test of spec.tests ?? []) {
			for (const result of test.results ?? []) {
				if (result.status === "failed" || result.status === "timedOut") {
					const firstErr = (
						result.errors?.[0]?.message ??
						result.error?.message ??
						""
					)
						.split("\n")[0]
						.slice(0, 300);
					failures.push({
						file: spec.file,
						title: here.concat(spec.title).join(" › "),
						project: test.projectName,
						status: result.status,
						message: firstErr,
					});
				}
			}
		}
	}
	for (const child of suite.suites ?? []) walk(child, here);
}
for (const suite of report.suites ?? []) walk(suite, []);

const stats = report.stats ?? {};
const lines = [];
lines.push(
	`**Summary:** ${stats.unexpected ?? failures.length} failed / ${stats.expected ?? "?"} passed / ${stats.flaky ?? 0} flaky`,
);
lines.push("");
if (failures.length === 0) {
	lines.push("_No failed specs found in report._");
} else {
	lines.push("| Project | Spec | Error |");
	lines.push("|---|---|---|");
	for (const f of failures) {
		const safeMsg = f.message.replace(/\|/g, "\\|");
		lines.push(
			`| ${f.project ?? ""} | \`${f.file}\` — ${f.title} | ${safeMsg} |`,
		);
	}
}
process.stdout.write(`${lines.join("\n")}\n`);
