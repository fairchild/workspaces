#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";

const resultsPath = process.argv[2] ?? ".lighthouseci/assertion-results.json";
if (!existsSync(resultsPath)) {
	process.stdout.write(
		"_No assertion-results.json produced (likely a collect failure)._\n",
	);
	process.exit(0);
}

const results = JSON.parse(readFileSync(resultsPath, "utf8"));
const failures = results.filter(
	(r) => r.level === "error" || r.passed === false,
);

const lines = [];
lines.push(
	`**Summary:** ${failures.length} assertion failure(s) out of ${results.length} checked`,
);
lines.push("");
if (failures.length === 0) {
	lines.push("_No failing assertions._");
} else {
	lines.push("| Audit | Expected | Actual | URL |");
	lines.push("|---|---|---|---|");
	for (const f of failures) {
		const expected =
			f.operator && f.expected !== undefined
				? `${f.operator} ${f.expected}`
				: "—";
		const actual = f.actual ?? "—";
		const url = f.url ?? "—";
		lines.push(
			`| \`${f.auditId ?? f.name}\` | ${expected} | ${actual} | ${url} |`,
		);
	}
}
process.stdout.write(`${lines.join("\n")}\n`);
