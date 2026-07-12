import { readFile } from "node:fs/promises";
import { describe, expect, test } from "vitest";

const packageRoot = new URL("../", import.meta.url);

describe("Folio style boundary", () => {
	test("exports its stylesheet as an intentional package side effect", async () => {
		const manifest = JSON.parse(
			await readFile(new URL("package.json", packageRoot), "utf8"),
		) as {
			exports: Record<string, unknown>;
			sideEffects: string[];
		};

		expect(manifest.exports["./styles.css"]).toBe("./src/styles.css");
		expect(manifest.sideEffects).toContain("./src/styles.css");
	});

	test("scans package source and scopes visual selectors to Folio roots", async () => {
		const styles = await readFile(new URL("src/styles.css", packageRoot), "utf8");
		const beforeScope = styles.slice(0, styles.indexOf("@scope"));

		expect(styles).toContain('@source "./**/*.{ts,tsx}"');
		expect(styles).toContain("@scope ([data-folio-root])");
		expect(styles).toContain("@layer folio-base");
		expect(styles).toContain("--folio-accent");
		expect(styles).not.toContain("url(");
		expect(styles).not.toMatch(/@source\s+["']\.\.\//);
		expect(beforeScope).not.toMatch(/(^|\n)\s*(html|body|:root|\*)\s*[{,]/);
		expect(
			styles
				.match(/@keyframes\s+([\w-]+)/g)
				?.every((rule) => rule.startsWith("@keyframes folio-")),
		).toBe(true);
	});

	test("keeps package-only selectors out of the Workspaces host sheet", async () => {
		const hostStyles = await readFile(
			new URL("../../../src/app/globals.css", import.meta.url),
			"utf8",
		);

		expect(hostStyles).toContain('@import "tailwindcss" source(none)');
		expect(hostStyles).toContain('@source "../**/*.{ts,tsx}"');
		expect(hostStyles).not.toContain(".reasoning-content");
		expect(hostStyles).not.toContain(".ellipsis-dots");
	});
});
