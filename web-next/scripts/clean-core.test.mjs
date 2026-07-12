import path from "node:path";
import { describe, expect, test } from "vitest";
import {
	DEFAULT_TARGETS,
	expandTargets,
	resolveWithinRoot,
	TARGETS,
} from "./clean-core.mjs";

describe("expandTargets", () => {
	test("no args expands the safe default trio, never deps", () => {
		const paths = expandTargets([]);
		expect(DEFAULT_TARGETS).not.toContain("deps");
		expect(paths).toContain(".next");
		expect(paths).toContain(".data");
		expect(paths).toContain("output");
		expect(paths).not.toContain("node_modules");
	});

	test("all expands every target exactly once", () => {
		const paths = expandTargets(["all"]);
		const everyPath = Object.values(TARGETS).flat();
		expect(new Set(paths)).toEqual(new Set(everyPath));
		expect(paths.length).toBe(new Set(paths).size);
	});

	test("named targets expand to just their paths, deduplicated", () => {
		expect(expandTargets(["build"])).toEqual([".next"]);
		expect(expandTargets(["build", "build", "deps"])).toEqual([
			".next",
			"node_modules",
		]);
	});

	test("Folio generated package state has explicit cleanup targets", () => {
		expect(expandTargets(["folio-build", "folio-artifact"])).toEqual([
			"packages/folio/dist",
			"artifacts/folio",
		]);
	});

	test("unknown targets are rejected with the valid vocabulary", () => {
		expect(() => expandTargets(["buld"])).toThrow(/unknown target.*buld.*valid/);
		expect(() => expandTargets(["hasOwnProperty"])).toThrow(/unknown target/);
	});
});

describe("resolveWithinRoot", () => {
	const root = path.resolve("/tmp/web-next");

	test("resolves a relative path inside the root", () => {
		expect(resolveWithinRoot(root, ".next", path.resolve, path.sep)).toBe(
			path.join(root, ".next"),
		);
	});

	test("refuses escapes and the root itself", () => {
		expect(() => resolveWithinRoot(root, "../elsewhere", path.resolve, path.sep)).toThrow(
			/outside the web-next root/,
		);
		expect(() => resolveWithinRoot(root, ".", path.resolve, path.sep)).toThrow(
			/root itself/,
		);
	});
});
