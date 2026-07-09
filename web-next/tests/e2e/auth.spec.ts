/*
 * Auth gate e2e: signed-out page requests redirect to sign-in, signed-out
 * /api/* requests get the route-level 401 JSON straight from the edge (no
 * HTML redirect — #828), the test-bypass button signs in as the allowlisted
 * user, a signed-in-but-not-allowlisted user gets the polite refusal (and
 * no data), and sign-in bounces users who are already in. The server runs
 * in bypass mode (e2e:server) where the test cookie is the session —
 * absence of it is a real signed-out request through the same middleware
 * as production.
 */
import { expect, test } from "@playwright/test";
import { E2E_LOGIN, signedInAs } from "../../playwright.config";

const signedOut = { cookies: [], origins: [] };

test.describe("signed out", () => {
	test.use({ storageState: signedOut });

	test("every app route redirects to sign-in", async ({ page }) => {
		for (const path of ["/", "/sessions/some-id", "/sessions/demo"]) {
			await page.goto(path);
			await expect(page).toHaveURL("/sign-in");
		}
		await expect(
			page.getByRole("button", { name: "Continue with GitHub" }),
		).toBeVisible();
	});

	test("the chat API is refused at the edge with 401 JSON, not an HTML redirect", async ({
		request,
	}) => {
		const response = await request.post("/api/sessions/any/chat", {
			data: { text: "hi" },
			maxRedirects: 0,
		});
		expect(response.status()).toBe(401);
		expect(response.headers()["location"]).toBeUndefined();
		expect(response.headers()["content-type"]).toContain("application/json");
		await expect(response.json()).resolves.toEqual({
			error: "not signed in as the allowed user",
		});
	});

	test("every unauthenticated /api/* route answers 401 JSON, no data leak (#828)", async ({
		request,
	}) => {
		const probes: Array<{ method: "GET" | "PATCH"; path: string }> = [
			{ method: "PATCH", path: "/api/sessions/any" },
			{ method: "GET", path: "/api/sessions/any/stream" },
			{ method: "GET", path: "/api/diag/gateway" },
			{ method: "GET", path: "/api/diag/preflight" },
			{ method: "GET", path: "/api/diag/prewarm" },
			{ method: "GET", path: "/api/repos" },
		];
		for (const { method, path } of probes) {
			const response = await request.fetch(path, { method, maxRedirects: 0 });
			expect(response.status(), `${method} ${path}`).toBe(401);
			expect(
				response.headers()["content-type"],
				`${method} ${path} content-type`,
			).toContain("application/json");
			const body: unknown = await response.json();
			expect(body, `${method} ${path} body`).toEqual({
				error: "not signed in as the allowed user",
			});
		}
	});

	test("the readiness probe answers signed out — /api/healthz is public (#987)", async ({
		request,
	}) => {
		const response = await request.get("/api/healthz", { maxRedirects: 0 });
		expect(response.status()).toBe(200);
		await expect(response.json()).resolves.toEqual({
			ok: true,
			localMode: false,
		});
	});

	test("the bypass button signs in as the allowlisted user", async ({
		page,
	}) => {
		await page.goto("/sign-in");
		await page
			.getByRole("button", { name: `continue as ${E2E_LOGIN} (test bypass)` })
			.click();
		await expect(page).toHaveURL("/");
		// Scoped to the masthead: bare getByText("Spaces") is a case-insensitive
		// substring match, so once sessions exist, rows for ".../workspaces"
		// match it too (order-dependent flake).
		await expect(page.getByRole("banner").getByText("Spaces")).toBeVisible();
	});
});

test.describe("not on the allowlist", () => {
	test.use({ storageState: signedInAs("mallory") });

	test("gets the polite refusal and no session data", async ({ page }) => {
		await page.goto("/");
		await expect(
			page.getByRole("heading", { name: /someone else/i }),
		).toBeVisible();
		await expect(page.getByText("mallory")).toBeVisible();
		// None of the home furniture rendered beneath the refusal.
		await expect(page.getByRole("link")).toHaveCount(0);
		await expect(page.getByTestId("new-session-picker")).toHaveCount(0);
	});

	test("the chat API refuses with 403 (the route gate, past middleware)", async ({
		request,
	}) => {
		const response = await request.post("/api/sessions/any/chat", {
			data: { text: "hi" },
		});
		expect(response.status()).toBe(403);
	});

	test("sign out returns to sign-in", async ({ page }) => {
		await page.goto("/");
		await page.getByRole("button", { name: "sign out" }).click();
		await expect(page).toHaveURL("/sign-in");
		// The cleared cookie no longer opens the app.
		await page.goto("/");
		await expect(page).toHaveURL("/sign-in");
	});
});

test("a signed-in user visiting sign-in is sent home", async ({ page }) => {
	await page.goto("/sign-in");
	await expect(page).toHaveURL("/");
});

test("a signed-in user can sign out from the sessions masthead and sign in again", async ({
	page,
}) => {
	await page.goto("/");
	const signOut = page.getByRole("button", { name: "sign out" });
	await expect(signOut).toBeVisible();

	await page.keyboard.press("Tab");
	await expect(signOut).toBeFocused();
	await page.keyboard.press("Enter");
	await expect(page).toHaveURL("/sign-in");

	await page.goto("/");
	await expect(page).toHaveURL("/sign-in");

	await page
		.getByRole("button", { name: `continue as ${E2E_LOGIN} (test bypass)` })
		.click();
	await expect(page).toHaveURL("/");
	await expect(page.getByRole("banner").getByText("Spaces")).toBeVisible();
});
