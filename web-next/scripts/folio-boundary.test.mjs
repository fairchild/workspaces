import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";

const WEB_NEXT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const FOLIO = path.join(WEB_NEXT, "packages", "folio");

function sourceFiles(root) {
	return fs.readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
		const target = path.join(root, entry.name);
		if (entry.isDirectory()) return sourceFiles(target);
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

	test("Workspaces consumes Folio through the named package", () => {
		for (const file of sourceFiles(path.join(WEB_NEXT, "src"))) {
			for (const specifier of importSpecifiers(file)) {
				expect(specifier, file).not.toContain("components/folio");
				expect(specifier, file).not.toContain("packages/folio/src");
			}
		}
	});

	test("manifest exposes one intentional source entry with host peers", () => {
		const manifest = JSON.parse(
			fs.readFileSync(path.join(FOLIO, "package.json"), "utf8"),
		);
		const appManifest = JSON.parse(
			fs.readFileSync(path.join(WEB_NEXT, "package.json"), "utf8"),
		);

		expect(manifest.name).toBe("@fairchild/folio");
		expect(manifest.exports).toEqual({
			".": { types: "./src/index.ts", import: "./src/index.ts" },
		});
		expect(manifest.files).toEqual(["src", "!src/**/*.test.ts"]);
		expect(manifest.peerDependencies).toMatchObject({
			ai: expect.any(String),
			react: expect.any(String),
			"react-dom": expect.any(String),
		});
		expect(manifest.folioCompatibility.next).toBe(">=15.5.0 <16");
		expect(appManifest.dependencies[manifest.name]).toBe("workspace:*");
	});
});
