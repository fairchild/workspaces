"use client";

/*
 * The ◐ light/dark toggle shared by the session masthead and the home
 * masthead — flips and persists the data-theme attribute via useThemeToggle.
 */
import { useThemeToggle } from "./use-theme";

export function ThemeToggle() {
	const toggleTheme = useThemeToggle();
	return (
		<span data-folio-root="inline">
			<button
				type="button"
				onClick={toggleTheme}
				title="Toggle light / dark"
				aria-label="Toggle light / dark theme"
				className="relative ml-4 rounded-md px-1.5 py-1 text-[13px] leading-none text-faint [transition:color_.2s_ease,transform_.35s_ease] after:absolute after:top-1/2 after:left-1/2 after:h-11 after:w-11 after:-translate-x-1/2 after:-translate-y-1/2 after:content-[''] hover:text-accent dark:rotate-180"
			>
				◐
			</button>
		</span>
	);
}
