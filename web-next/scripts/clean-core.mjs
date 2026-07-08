/*
 * Pure target-resolution core for scripts/clean.mjs — maps named clean
 * targets onto the fixed set of web-next-relative paths they cover. Pure and
 * I/O-free so the expansion/validation rules are unit-testable (see
 * clean-core.test.mjs), mirroring the validate-core.mjs pattern.
 */

/** Named targets → the web-next-relative paths they remove. */
export const TARGETS = {
	build: [".next"],
	data: [".data"],
	"e2e-data": [".data/e2e.db", ".data/e2e.db-shm", ".data/e2e.db-wal"],
	artifacts: [
		"output",
		"playwright-report",
		"test-results",
		"perf/results.json",
		"perf/results.md",
		"perf/results-deployed.json",
		"perf/results-deployed.md",
	],
	deps: ["node_modules"],
};

/** No-arg default: the safe everyday trio (never deps). */
export const DEFAULT_TARGETS = ["build", "data", "artifacts"];

export const USAGE =
	"usage: pnpm run clean [build|data|e2e-data|artifacts|deps|all]... [--dry-run]";

/**
 * Expands target names into a deduplicated list of web-next-relative paths.
 * No names → DEFAULT_TARGETS; `all` → every target. Throws on unknown names.
 */
export function expandTargets(names) {
	const requested = names.length === 0 ? DEFAULT_TARGETS : names;
	const expanded = requested.includes("all") ? Object.keys(TARGETS) : requested;
	const unknown = expanded.filter((name) => !Object.hasOwn(TARGETS, name));
	if (unknown.length > 0) {
		throw new Error(
			`unknown target(s): ${unknown.join(", ")} — valid: ${[...Object.keys(TARGETS), "all"].join(", ")}`,
		);
	}
	return [...new Set(expanded.flatMap((name) => TARGETS[name]))];
}

/**
 * Resolves a relative path against the web-next root and refuses anything
 * that escapes it. Paths come from the fixed TARGETS map, so escape is
 * impossible by construction — this guard keeps that true if the map changes.
 */
export function resolveWithinRoot(root, relPath, resolve, sep) {
	const abs = resolve(root, relPath);
	if (abs !== root && !abs.startsWith(root + sep)) {
		throw new Error(`refusing to touch a path outside the web-next root: ${abs}`);
	}
	if (abs === root) {
		throw new Error("refusing to remove the web-next root itself");
	}
	return abs;
}
