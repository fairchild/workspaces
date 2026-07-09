import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
	ensureLocalSignInToken,
	localSignInTokenMatches,
	localTokenPath,
} from "./local-token";

const dirs: string[] = [];

function env() {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "web-next-local-token-"));
	dirs.push(dir);
	return { WEB_NEXT_LOCAL_MODE: "1", WEB_NEXT_DATA_DIR: dir };
}

afterEach(() => {
	for (const dir of dirs.splice(0)) {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

describe("local sign-in token", () => {
	it("mints once, persists under WEB_NEXT_DATA_DIR, and reuses the token", () => {
		const testEnv = env();
		const first = ensureLocalSignInToken(testEnv);
		const second = ensureLocalSignInToken(testEnv);
		expect(first).toBe(second);
		expect(first).toHaveLength(43);
		expect(fs.readFileSync(localTokenPath(testEnv), "utf8").trim()).toBe(first);
	});

	it("compares the supplied token without accepting wrong values", () => {
		const testEnv = env();
		const token = ensureLocalSignInToken(testEnv);
		expect(localSignInTokenMatches(token, testEnv)).toBe(true);
		expect(localSignInTokenMatches(`${token}x`, testEnv)).toBe(false);
		expect(localSignInTokenMatches("wrong", testEnv)).toBe(false);
		expect(localSignInTokenMatches("", testEnv)).toBe(false);
	});

	it("uses WEB_NEXT_LOCAL_TOKEN when middleware/startup provided it", () => {
		expect(
			localSignInTokenMatches("from-env", {
				WEB_NEXT_LOCAL_MODE: "1",
				WEB_NEXT_LOCAL_TOKEN: "from-env",
			}),
		).toBe(true);
	});
});
