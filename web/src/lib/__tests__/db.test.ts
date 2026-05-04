import { describe, expect, it } from "vitest";
import { getDatabaseURL } from "../db";

describe("getDatabaseURL", () => {
	it("uses TURSO_DATABASE_URL when configured", () => {
		expect(
			getDatabaseURL({
				TURSO_DATABASE_URL: "libsql://example.turso.io",
				VERCEL_ENV: "preview",
			}),
		).toBe("libsql://example.turso.io");
	});

	it("uses an ephemeral sqlite file on Vercel preview without Turso env", () => {
		expect(
			getDatabaseURL({
				VERCEL: "1",
				VERCEL_ENV: "preview",
				VERCEL_URL: "spaces-preview.vercel.app",
			}),
		).toBe("file:/tmp/workspaces-auth.db");
	});

	it("fails closed on production Vercel without Turso env", () => {
		expect(() =>
			getDatabaseURL({
				VERCEL: "1",
				VERCEL_ENV: "production",
				VERCEL_URL: "spaces.cloudcompute.com",
			}),
		).toThrow(/TURSO_DATABASE_URL/);
	});

	it("keeps the local file fallback outside Vercel", () => {
		expect(getDatabaseURL({ NODE_ENV: "development" })).toBe(
			"file:data/auth.db",
		);
	});
});
