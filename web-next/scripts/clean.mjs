/*
 * Deletes web-next build/test state through one entrypoint:
 * `pnpm run clean [build|data|artifacts|deps|all]... [--dry-run]`.
 * Exists so agents and unattended sessions never need ad-hoc `rm -rf`,
 * which trips shell-permission prompts; one fixed, allowlistable command
 * covers the recurring cases (clean builds, throwaway e2e/perf databases,
 * test artifacts). Target map + safety rules live in clean-core.mjs.
 */
import { existsSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { expandTargets, resolveWithinRoot, USAGE } from "./clean-core.mjs";

const WEB_NEXT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const names = args.filter((arg) => arg !== "--dry-run");

let relPaths;
try {
	relPaths = expandTargets(names);
} catch (error) {
	console.error(error instanceof Error ? error.message : String(error));
	console.error(USAGE);
	process.exit(1);
}

for (const relPath of relPaths) {
	const abs = resolveWithinRoot(WEB_NEXT_ROOT, relPath, path.resolve, path.sep);
	if (!existsSync(abs)) {
		console.log(`absent   ${relPath}`);
		continue;
	}
	if (dryRun) {
		console.log(`would rm ${relPath}`);
		continue;
	}
	rmSync(abs, { recursive: true, force: true });
	console.log(`removed  ${relPath}`);
}
