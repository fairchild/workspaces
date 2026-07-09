/*
 * Validates in-app redirect targets from `?redirect=` query/form params (the
 * embedded-native sign-in deep link, #987). Only same-origin relative paths
 * survive; everything else falls back to "/" so a crafted sign-in link can
 * never bounce the browser to another host. Callers that resolve the result
 * against an origin (`new URL(path, origin)`) must still verify the resolved
 * origin matches — that backstop keeps this validator's correctness
 * non-load-bearing for the security property.
 * Pure and import-free, so edge middleware can share it with server actions.
 */
export function safeRedirectPath(value: string | null | undefined): string {
	if (!value || !value.startsWith("/")) return "/";
	// Callers hand us percent-DECODED values (searchParams.get, form fields),
	// and WHATWG URL parsing strips tab/LF/CR anywhere in its input — so
	// "/\t/evil.com" would collapse to protocol-relative "//evil.com" after
	// the prefix checks passed. Reject control characters (and raw spaces,
	// which the parser trims at the ends) outright instead of mirroring the
	// parser's stripping rules.
	if (/[\u0000-\u0020\u007f]/.test(value)) return "/";
	// Browsers normalize "\" to "/" — anywhere in the URL, not just up front.
	if (value.includes("\\")) return "/";
	if (value.startsWith("//")) return "/";
	return value;
}
