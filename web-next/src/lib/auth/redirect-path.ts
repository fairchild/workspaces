/*
 * Validates in-app redirect targets from `?redirect=` query/form params (the
 * embedded-native sign-in deep link, #987). Only same-origin relative paths
 * survive; absolute URLs, protocol-relative `//host`, and the backslash
 * variant `/\host` (browsers normalize `\` to `/`) all fall back to "/" so a
 * crafted sign-in link can never bounce the browser to another host.
 * Pure and import-free, so edge middleware can share it with server actions.
 */
export function safeRedirectPath(value: string | null | undefined): string {
	if (!value || !value.startsWith("/")) return "/";
	if (value.startsWith("//") || value.startsWith("/\\")) return "/";
	return value;
}
