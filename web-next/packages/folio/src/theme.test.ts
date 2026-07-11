import { describe, expect, it } from "vitest";
import { resolveTheme, themeInitScript } from "./theme";

describe("resolveTheme", () => {
	it("follows system preference when nothing is forced or stored", () => {
		expect(resolveTheme("", null, false)).toBe("light");
		expect(resolveTheme("", null, true)).toBe("dark");
	});

	it("prefers a stored toggle choice over system preference", () => {
		expect(resolveTheme("", "light", true)).toBe("light");
		expect(resolveTheme("", "dark", false)).toBe("dark");
	});

	it("lets a #light/#dark hash override everything", () => {
		expect(resolveTheme("dark", "light", false)).toBe("dark");
		expect(resolveTheme("light", "dark", true)).toBe("light");
	});

	it("ignores unrecognized hash and storage values", () => {
		expect(resolveTheme("sepia", "solarized", true)).toBe("dark");
		expect(resolveTheme("sepia", "solarized", false)).toBe("light");
	});

	it("serializes the resolver into the init script", () => {
		// The blocking script embeds resolveTheme via toString; if the function
		// stops being self-contained, the reference breaks at runtime.
		expect(themeInitScript).toContain("document.documentElement.dataset.theme");
		expect(() => new Function(themeInitScript)).not.toThrow();
	});
});
