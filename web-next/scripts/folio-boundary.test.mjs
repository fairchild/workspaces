import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";

const WEB_NEXT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const FOLIO = path.join(WEB_NEXT, "packages", "folio");
const SKIPPED_CONSUMER_DIRECTORIES = new Set([
	".next",
	"artifacts",
	"coverage",
	"node_modules",
	"output",
	"playwright-report",
	"test-results",
]);
const PUBLIC_FOLIO_IMPORTS = new Set([
	"@fairchild/folio",
	"@fairchild/folio/format",
]);
const require = createRequire(import.meta.url);

function sourceFiles(root, skippedDirectories = new Set()) {
	return fs.readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
		const target = path.join(root, entry.name);
		if (entry.isDirectory()) {
			return skippedDirectories.has(entry.name)
				? []
				: sourceFiles(target, skippedDirectories);
		}
		return /\.[cm]?[jt]sx?$/.test(entry.name) ? [target] : [];
	});
}

function importSpecifiers(file) {
	const source = fs.readFileSync(file, "utf8");
	return [...source.matchAll(/(?:from|import)\s*[(']?\s*["']([^"']+)["']/g)].map(
		(match) => match[1],
	);
}

describe("Folio package boundary", () => {
	test("package sources never reach into Workspaces application aliases", () => {
		for (const file of sourceFiles(path.join(FOLIO, "src"))) {
			for (const specifier of importSpecifiers(file)) {
				expect(specifier, file).not.toMatch(/^@\//);
				expect(specifier, file).not.toMatch(/^\.\.\//);
			}
		}
	});

	test("Workspaces consumes Folio through declared public package entries", () => {
		for (const file of sourceFiles(WEB_NEXT, SKIPPED_CONSUMER_DIRECTORIES)) {
			for (const specifier of importSpecifiers(file)) {
				expect(specifier, file).not.toContain("components/folio");
				expect(specifier, file).not.toContain("packages/folio/src");
				if (specifier.startsWith("@fairchild/folio")) {
					expect(PUBLIC_FOLIO_IMPORTS, file).toContain(specifier);
				}
			}
		}
	});

	test("public package entries resolve from Node CommonJS graphs", () => {
		for (const specifier of PUBLIC_FOLIO_IMPORTS) {
			expect(() => require.resolve(specifier), specifier).not.toThrow();
		}
	});

	test("manifest exposes intentional source entries with host peers", () => {
		const manifest = JSON.parse(
			fs.readFileSync(path.join(FOLIO, "package.json"), "utf8"),
		);
		const appManifest = JSON.parse(
			fs.readFileSync(path.join(WEB_NEXT, "package.json"), "utf8"),
		);

		expect(manifest.name).toBe("@fairchild/folio");
		expect(manifest.exports).toEqual({
			".": {
				types: "./src/index.ts",
				import: "./src/index.ts",
				default: "./src/index.ts",
			},
			"./format": {
				types: "./src/format.ts",
				import: "./src/format.ts",
				default: "./src/format.ts",
			},
		});
		expect(manifest.files).toEqual([
			"src",
			"!src/**/*.test.ts",
			"!src/**/*.test.tsx",
		]);
		expect(manifest.peerDependencies).toMatchObject({
			ai: expect.any(String),
			react: expect.any(String),
			"react-dom": expect.any(String),
		});
		expect(manifest.folioCompatibility.next).toBe(">=15.5.0 <16");
		expect(appManifest.dependencies[manifest.name]).toBe("workspace:*");
		expect(fs.readFileSync(path.join(FOLIO, "LICENSE"), "utf8")).toBe(
			fs.readFileSync(path.join(WEB_NEXT, "..", "LICENSE"), "utf8"),
		);
	});
});
