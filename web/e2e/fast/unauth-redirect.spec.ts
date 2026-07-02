import { expect, test } from "@playwright/test";

// These specs assert middleware behavior and rely on production-mode auth
// (no dev bypass): they pass in CI (`pnpm start`) and are red under `pnpm dev`
// by design — see web/docs/local-dev.md.
test.describe("Auth redirect", () => {
	test("GET /dashboard without auth redirects to sign-in", async ({ page }) => {
		await page.goto("/dashboard");
		await expect(page).toHaveURL(/\/sign-in/);
	});

	test("GET /dashboard with an invalid session cookie redirects from middleware (no shell flash)", async ({
		browser,
		baseURL,
	}) => {
		const context = await browser.newContext();
		// Seed a session token plus a malformed cookie-cache cookie. Middleware
		// must reject it at the document request itself — asserting on the
		// redirect response (maxRedirects: 0), not the rendered page, proves the
		// gate happens at the edge with no dashboard HTML served first.
		const url = baseURL ?? "http://localhost:3000";
		await context.addCookies([
			{ name: "better-auth.session_token", value: "forged-invalid-token", url },
			{
				name: "better-auth.session_data",
				// base64url("not-a-valid-session") — decodes but is not a valid
				// signed session payload, so getCookieCache rejects it.
				value: "bm90LWEtdmFsaWQtc2Vzc2lvbg",
				url,
			},
		]);

		const response = await context.request.get("/dashboard", {
			maxRedirects: 0,
		});

		expect([302, 303, 307, 308]).toContain(response.status());
		expect(response.headers().location).toMatch(/\/sign-in/);

		await context.close();
	});
});
