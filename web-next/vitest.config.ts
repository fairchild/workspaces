import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
	// Mirrors tsconfig.json's "@/*" path so a value import (not just `import
	// type`) across the lib/ ↔ components/ boundary resolves under vitest too
	// (#824: lib/transcript/turn-stats.ts reuses components/folio/ledger.ts's
	// token formatter).
	resolve: {
		alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) },
	},
	test: {
		environment: "node",
		include: [
			"src/**/*.test.ts",
			"packages/**/*.test.{ts,tsx}",
			"scripts/**/*.test.mjs",
			"perf/**/*.test.mjs",
		],
	},
});
