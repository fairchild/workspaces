import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

describe("e2e:server environment", () => {
	test("clears GitHub App credentials so the repo directory stays fixture-backed", () => {
		const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
		const script = pkg.scripts["e2e:server"];
		expect(script).toContain("GITHUB_WEB_WORKSPACES_APP_ID=");
		expect(script).toContain("GITHUB_APP_PRIVATE_KEY=");
	});
});
