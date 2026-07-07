/*
 * Regression guard for the #817 spec curation: every test carrying the
 * `@deployed-safe` grep tag (what `pnpm validate`'s e2e stage replays
 * against real deployments) must live in a file that is genuinely
 * read-mostly — sessions-demo.spec.ts renders fixture data, no backend (see
 * its top-of-file doc block). sessions.spec.ts and auth.spec.ts drive real
 * session/turn creation and sign-out; tagging anything there would send
 * validate's deployed run to mutate state or trigger a real (costly)
 * agent-runtime turn. This test reads the actual spec files, so a future
 * `@deployed-safe` added to the wrong file fails CI instead of only being
 * caught by a careful reviewer.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";

const E2E_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "tests", "e2e");

function taggedTestTitles(file) {
	const text = readFileSync(path.join(E2E_DIR, file), "utf8");
	const titles = [...text.matchAll(/^test\(\s*"([^"]*)"/gm)].map((m) => m[1]);
	return titles.filter((title) => title.includes("@deployed-safe"));
}

describe("@deployed-safe spec curation (#817)", () => {
	test("sessions-demo.spec.ts (fixture-rendered, no backend) is fully tagged", () => {
		const tagged = taggedTestTitles("sessions-demo.spec.ts");
		expect(tagged.length).toBeGreaterThanOrEqual(7);
	});

	test("sessions.spec.ts (real session/turn creation) carries no deployed-safe tag", () => {
		expect(taggedTestTitles("sessions.spec.ts")).toEqual([]);
	});

	test("auth.spec.ts (sign-out, bypass-only forged cookies) carries no deployed-safe tag", () => {
		expect(taggedTestTitles("auth.spec.ts")).toEqual([]);
	});

	test("terminal.spec.ts (session creation + a live sandbox shell) carries no deployed-safe tag", () => {
		expect(taggedTestTitles("terminal.spec.ts")).toEqual([]);
	});
});
