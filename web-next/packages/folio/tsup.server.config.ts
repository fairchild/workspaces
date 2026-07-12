/* Builds Folio's server-safe entries without hashed shared declaration chunks. */
import { defineConfig, type Options } from "tsup";

const shared = {
	format: ["esm"],
	target: "es2022",
	platform: "neutral",
	dts: true,
	sourcemap: true,
	splitting: false,
	clean: false,
	outDir: "dist",
	external: ["./conversation.js", "ai", "react", "react-dom"],
} satisfies Options;

export default defineConfig(
	Object.entries({
		conversation: "src/conversation.ts",
		format: "src/format.ts",
		theme: "src/theme-entry.ts",
		testing: "src/testing-entry.ts",
	}).map(([name, source]) => ({
		...shared,
		entry: { [name]: source },
	})),
);
