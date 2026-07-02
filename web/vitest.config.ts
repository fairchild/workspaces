import path from "node:path";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

const alias = { "@": path.resolve(__dirname, "src") };

export default defineConfig({
	test: {
		// Two projects share one `vitest run` invocation (and one `pnpm test`
		// CI step): `unit` for pure module/route logic (node, fast, no DOM),
		// `component` for dashboard components that need a real DOM to catch
		// hook-order and effect/race regressions. Keep pure logic in `unit` —
		// it stays fast and doesn't need jsdom's overhead.
		projects: [
			{
				resolve: { alias },
				test: {
					name: "unit",
					environment: "node",
					// Existing glob is unchanged: everything under exclude/exclude
					// defaults except the new component-test tree.
					exclude: ["e2e/**", "node_modules/**", "src/**/__tests__/*.test.tsx"],
					// Multiple test files touch the same local SQLite file via
					// `ensureXTable` migrations. Parallel workers racing on DDL
					// produce SQLITE_BUSY; serialize file execution to match the
					// single-writer reality of production.
					fileParallelism: false,
				},
			},
			{
				resolve: { alias },
				// tsconfig.json sets `jsx: "preserve"` for Next's own SWC-based
				// JSX transform, and rolldown-vite's built-in oxc transform (the
				// `esbuild` config option is ignored once `@vitejs/plugin-react`
				// is present) doesn't expose a jsx override of its own — so
				// component tests need a real JSX-transforming plugin, same as
				// any non-Next Vite + React project would.
				plugins: [react()],
				test: {
					name: "component",
					// jsdom over happy-dom: happy-dom's incomplete CSSOM/layout
					// shims have known friction with React 19's act()/event
					// batching on Next 15 client components (StrictMode double-
					// invoke, portal/event delegation). jsdom is the slower but
					// more complete/compatible choice and these are a handful of
					// targeted component tests, not a perf-sensitive suite.
					environment: "jsdom",
					include: ["src/**/__tests__/*.test.tsx"],
					exclude: ["e2e/**", "node_modules/**"],
				},
			},
		],
	},
});
