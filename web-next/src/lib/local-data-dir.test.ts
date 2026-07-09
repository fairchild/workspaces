import { describe, expect, it } from "vitest";
import { resolveSessionsDatabaseUrl, resolveWebNextDataDir } from "./local-data-dir";

describe("local data dir resolution", () => {
	it("defaults to .data", () => {
		expect(resolveWebNextDataDir({})).toBe(".data");
		expect(resolveSessionsDatabaseUrl({})).toBe("file:.data/sessions.db");
	});

	it("moves the default SQLite file under WEB_NEXT_DATA_DIR", () => {
		expect(resolveSessionsDatabaseUrl({ WEB_NEXT_DATA_DIR: "/tmp/spaces-local" })).toBe(
			"file:/tmp/spaces-local/sessions.db",
		);
	});

	it("keeps an explicit database URL authoritative", () => {
		expect(
			resolveSessionsDatabaseUrl({
				WEB_NEXT_DATA_DIR: "/tmp/spaces-local",
				SESSIONS_DATABASE_URL: "file:/tmp/custom.db",
			}),
		).toBe("file:/tmp/custom.db");
	});
});
