/*
 * Folio theme resolution: system preference by default, an explicit toggle
 * choice (localStorage) overrides it, and a #light/#dark URL hash overrides
 * both — hash parity with the refine-folio prototype for deterministic
 * screenshots. themeInitScript runs blocking before first paint.
 */

export type Theme = "light" | "dark";

export const THEME_STORAGE_KEY = "folio-theme";

/**
 * Resolution order: hash > stored toggle choice > system preference.
 * Self-contained on purpose — it is serialized into themeInitScript.
 */
export function resolveTheme(
	hash: string,
	stored: string | null,
	systemPrefersDark: boolean,
): Theme {
	if (hash === "light" || hash === "dark") return hash;
	if (stored === "light" || stored === "dark") return stored;
	return systemPrefersDark ? "dark" : "light";
}

/** Inline <script> body: applies the resolved theme before first paint. */
export const themeInitScript = `(function () {
	var resolve = ${resolveTheme.toString()};
	var stored = null;
	try { stored = localStorage.getItem("${THEME_STORAGE_KEY}"); } catch (e) {}
	document.documentElement.dataset.theme = resolve(
		location.hash.slice(1),
		stored,
		window.matchMedia("(prefers-color-scheme: dark)").matches
	);
})();`;
