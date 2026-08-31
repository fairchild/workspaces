/*
 * Coverage for `config.matcher` itself, not the `middleware` function (#1467).
 * middleware.test.ts calls the export directly, so it can only prove what the
 * gate decides once it runs — never which requests reach it. The matcher is
 * where the local-mode Host gate was silently skipped: the old
 * `.*\..*` alternative excluded every dotted path, so
 * `/api/auth/callback/foo.bar` bypassed the edge on the one route whose job is
 * minting credentials.
 *
 * Next compiles `config.matcher` at build time, so a hand-written regex here
 * would test our translation rather than Next's. We call Next's own
 * `getMiddlewareMatchers` instead — an internal with no published types, hence
 * the narrow require shim. If Next moves it the import throws and this test
 * fails loudly; it cannot quietly start passing for the wrong reason. Matching
 * is `new RegExp(regexp).test(pathname)`, exactly what getMiddlewareRouteMatcher
 * does for matchers carrying no `has`/`missing` clause.
 */
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";
import { config } from "./middleware";

type CompiledMatcher = { regexp: string; originalSource: string };

const nodeRequire = createRequire(import.meta.url);
const { getMiddlewareMatchers } = nodeRequire(
	"next/dist/build/analysis/get-page-static-info",
) as {
	getMiddlewareMatchers: (
		matcher: string | string[],
		nextConfig: Record<string, unknown>,
	) => CompiledMatcher[];
};

const compiled = getMiddlewareMatchers(config.matcher, {});

function middlewareRunsOn(pathname: string): boolean {
	return compiled.some((matcher) => new RegExp(matcher.regexp).test(pathname));
}

describe("middleware matcher", () => {
	it("runs on a dotted path under /api/auth — the credential-minting route", () => {
		// The sharp case: in local mode the Host gate runs before isPublic(), so
		// it is the only thing standing between an attacker-controlled Host and
		// the Better Auth catch-all. Better Auth does not close this itself —
		// with BETTER_AUTH_URL unset (local mode forbids the OAuth env entirely)
		// its trustedOrigins are derived from the request's own origin.
		expect(middlewareRunsOn("/api/auth/callback/foo.bar")).toBe(true);
		expect(middlewareRunsOn("/api/auth/callback/github.callback")).toBe(true);
	});

	it("runs on the dotted API path from the report", () => {
		expect(middlewareRunsOn("/api/sessions/foo.bar")).toBe(true);
	});

	it("runs on every API path, dotted or not, including asset-looking suffixes", () => {
		for (const pathname of [
			"/api",
			"/api/repos",
			"/api/healthz",
			"/api/sessions/a.b.c",
			"/api/manifest.json",
			"/api/sessions/logo.svg",
		]) {
			expect(middlewareRunsOn(pathname), pathname).toBe(true);
		}
	});

	it("runs on dotted page paths too — the gate is meant to be uniform", () => {
		for (const pathname of ["/sessions/abc.def", "/sign-in.html"]) {
			expect(middlewareRunsOn(pathname), pathname).toBe(true);
		}
	});

	it("still runs on ordinary page paths", () => {
		for (const pathname of ["/", "/sign-in", "/sessions/abc", "/new"]) {
			expect(middlewareRunsOn(pathname), pathname).toBe(true);
		}
	});

	it("runs on /sign-out — the gate is what lands a second sign-out on /sign-in", () => {
		// The route handler carries no auth gate of its own (#1488): a caller
		// with no session is meant to be bounced to the sign-in page by the
		// edge, which only holds while the matcher reaches this path.
		expect(middlewareRunsOn("/sign-out")).toBe(true);
	});

	it("still skips the static asset paths the exclusion exists for", () => {
		for (const pathname of [
			"/_next/static/chunks/main-abc123.js",
			"/_next/static/css/app.css",
			"/_next/static/media/font.woff2",
			"/_next/image",
			"/favicon.ico",
			"/logo.svg",
			"/icon.png",
			"/robots.txt",
			"/sitemap.xml",
			"/manifest.webmanifest",
			"/fonts/inter.woff2",
		]) {
			expect(middlewareRunsOn(pathname), pathname).toBe(false);
		}
	});
});
