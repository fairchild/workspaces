/**
 * Folio's narrow theme entry. Hosts can initialize and toggle presentation
 * without pulling the conversation/session component graph into every route.
 */
export { ThemeToggle } from "./theme-toggle";
export {
	THEME_STORAGE_KEY,
	resolveTheme,
	themeInitScript,
	type Theme,
} from "./theme";
