/**
 * Folio's server-safe theme entry. Hosts can initialize presentation without
 * pulling React or the conversation component graph into layouts.
 */
export {
	THEME_STORAGE_KEY,
	resolveTheme,
	themeInitScript,
	type Theme,
} from "./theme";
