"use client";

/*
 * Client side of the Folio theme: a toggle that flips and persists the
 * data-theme attribute, plus listeners keeping hash (#light/#dark) and
 * system-preference changes live after the pre-paint init script ran.
 */
import { useCallback, useEffect } from "react";
import { resolveTheme, THEME_STORAGE_KEY, type Theme } from "./theme";

function applyTheme(theme: Theme) {
	document.documentElement.dataset.theme = theme;
}

function readStoredTheme(): string | null {
	try {
		return localStorage.getItem(THEME_STORAGE_KEY);
	} catch {
		return null;
	}
}

export function useThemeToggle(): () => void {
	useEffect(() => {
		const media = window.matchMedia("(prefers-color-scheme: dark)");
		const reapply = () =>
			applyTheme(
				resolveTheme(location.hash.slice(1), readStoredTheme(), media.matches),
			);
		window.addEventListener("hashchange", reapply);
		media.addEventListener("change", reapply);
		return () => {
			window.removeEventListener("hashchange", reapply);
			media.removeEventListener("change", reapply);
		};
	}, []);

	return useCallback(() => {
		const next: Theme =
			document.documentElement.dataset.theme === "dark" ? "light" : "dark";
		applyTheme(next);
		try {
			localStorage.setItem(THEME_STORAGE_KEY, next);
		} catch {
			// Private mode etc. — the toggle still works for this page view.
		}
	}, []);
}
