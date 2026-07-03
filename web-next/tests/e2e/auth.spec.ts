/*
 * Auth gate e2e: signed-out requests redirect to sign-in, the test-bypass
 * button signs in as the allowlisted user, a signed-in-but-not-allowlisted
 * user gets the polite refusal (and no data), and sign-in bounces users who
 * are already in. The server runs in bypass mode (e2e:server) where the
 * test cookie is the session — absence of it is a real signed-out request
 * through the same middleware as production.
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

	test("the chat API is bounced at the edge, not served", async ({
		request,
	}) => {
		const response = await request.post("/api/sessions/any/chat", {
			data: { text: "hi" },
			maxRedirects: 0,
		});
		expect(response.status()).toBe(307);
		expect(response.headers()["location"]).toContain("/sign-in");
	});

	test("the bypass button signs in as the allowlisted user", async ({
		page,
	}) => {
		await page.goto("/sign-in");
		await page
			.getByRole("button", { name: `continue as ${E2E_LOGIN} (test bypass)` })
			.click();
		await expect(page).toHaveURL("/");
		await expect(page.getByText("Spaces")).toBeVisible();
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
