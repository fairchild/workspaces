import path from "node:path";
import { defineConfig } from "vitest/config";

export default defineConfig({
	test: {
		environment: "node",
		exclude: ["e2e/**", "node_modules/**"],
		// Multiple test files touch the same local SQLite file via
		// `ensureXTable` migrations. Parallel workers racing on DDL
		// produce SQLITE_BUSY; serialize file execution to match the
		// single-writer reality of production.
		fileParallelism: false,
	},
	resolve: {
		alias: {
			"@": path.resolve(__dirname, "src"),
		},
	},
});
