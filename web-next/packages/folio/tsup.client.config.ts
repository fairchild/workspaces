/* Builds Folio's React entry points with the client boundary preserved. */
import { defineConfig } from "tsup";

export default defineConfig({
	entry: {
		index: "src/index.ts",
		"theme-toggle": "src/theme-toggle-entry.ts",
	},
	format: ["esm"],
	target: "es2022",
	platform: "browser",
	dts: true,
	sourcemap: true,
	splitting: false,
	clean: false,
	outDir: "dist",
	banner: { js: '"use client";' },
	external: ["ai", "react", "react-dom"],
});
