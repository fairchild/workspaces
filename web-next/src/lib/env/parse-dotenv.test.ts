import { describe, expect, test } from "vitest";

import { parseDotEnv } from "./parse-dotenv";

describe("parseDotEnv", () => {
	test("keeps a multi-line double-quoted PEM intact (the daily-driver regression)", () => {
		const pem =
			"-----BEGIN RSA PRIVATE KEY-----\nMIIEabcd1234\nEFGH5678\n-----END RSA PRIVATE KEY-----";
		const env = parseDotEnv(`GITHUB_APP_PRIVATE_KEY="${pem}"\nOTHER=x`);
		// A naive line-splitter would yield only the BEGIN header here.
		expect(env.GITHUB_APP_PRIVATE_KEY).toBe(pem);
		expect(env.GITHUB_APP_PRIVATE_KEY).toContain("-----END RSA PRIVATE KEY-----");
		expect(env.OTHER).toBe("x");
	});

	test("double-quoted values unescape \\n; single-quoted are literal", () => {
		expect(parseDotEnv('A="a\\nb"').A).toBe("a\nb");
		expect(parseDotEnv("B='a\\nb'").B).toBe("a\\nb");
	});

	test("unquoted values are the rest of the line, trimmed (no comment stripping)", () => {
		expect(parseDotEnv("A=hello").A).toBe("hello");
		// Matches the loader this replaces: an unquoted `#` is part of the value.
		expect(parseDotEnv("A=ab#cd").A).toBe("ab#cd");
		expect(parseDotEnv("A=hello   ").A).toBe("hello");
	});

	test("skips comments and blanks, supports `export` and dotted keys", () => {
		const env = parseDotEnv("# header\n\nexport A=1\nNEXT_PUBLIC.X=2\n");
		expect(env.A).toBe("1");
		expect(env["NEXT_PUBLIC.X"]).toBe("2");
	});

	test("a value's inline # is preserved inside quotes", () => {
		expect(parseDotEnv('A="ab#cd"').A).toBe("ab#cd");
	});
});
