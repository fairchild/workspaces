import { describe, expect, it } from "vitest";
import { VALID_STATUSES, isWorkspace } from "../workspace-utils";

function validWorkspace(overrides: Record<string, unknown> = {}) {
	return {
		id: "ws-1",
		name: "my-workspace",
		path: "/Users/dev/project",
		status: "active",
		backendIdentifier: "local",
		...overrides,
	};
}

describe("isWorkspace", () => {
	it("accepts a valid workspace object", () => {
		expect(isWorkspace(validWorkspace())).toBe(true);
	});

	for (const status of ["provisioning", "active", "stopped", "archived"]) {
		it(`accepts status "${status}"`, () => {
			expect(isWorkspace(validWorkspace({ status }))).toBe(true);
		});
	}

	it("rejects invalid status", () => {
		expect(isWorkspace(validWorkspace({ status: "running" }))).toBe(false);
	});

	it("rejects missing id", () => {
		const { id, ...rest } = validWorkspace();
		expect(isWorkspace(rest)).toBe(false);
	});

	it("rejects missing name", () => {
		const { name, ...rest } = validWorkspace();
		expect(isWorkspace(rest)).toBe(false);
	});

	it("rejects missing path", () => {
		const { path, ...rest } = validWorkspace();
		expect(isWorkspace(rest)).toBe(false);
	});

	it("rejects missing backendIdentifier", () => {
		const { backendIdentifier, ...rest } = validWorkspace();
		expect(isWorkspace(rest)).toBe(false);
	});

	it("rejects null", () => {
		expect(isWorkspace(null)).toBe(false);
	});

	it("rejects non-object values", () => {
		expect(isWorkspace("string")).toBe(false);
		expect(isWorkspace(42)).toBe(false);
		expect(isWorkspace(undefined)).toBe(false);
	});

	it("rejects wrong field types", () => {
		expect(isWorkspace(validWorkspace({ id: 123 }))).toBe(false);
		expect(isWorkspace(validWorkspace({ name: null }))).toBe(false);
	});
});

describe("VALID_STATUSES", () => {
	it("contains exactly 4 statuses", () => {
		expect(VALID_STATUSES.size).toBe(4);
	});
});
