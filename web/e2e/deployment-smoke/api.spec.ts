import { expect, test } from "@playwright/test";

test.describe("Deployment smoke API", () => {
	test("rejects unauthenticated workspace sync requests", async ({ request }) => {
		const response = await request.post("/api/workspaces/sync", {
			data: { workspaces: [] },
		});

		expect(response.status()).toBe(401);
		expect(await response.json()).toEqual({ error: "unauthorized" });
	});

	test("starts GitHub social sign-in from the served origin", async ({
		baseURL,
		request,
	}) => {
		test.skip(
			process.env.PLAYWRIGHT_SKIP_WEB_SERVER !== "1" &&
				!process.env.GITHUB_WEB_WORKSPACES_CLIENT_ID,
			"local smoke needs OAuth env to exercise social sign-in",
		);

		const origin = baseURL ? new URL(baseURL).origin : "http://localhost:3000";
		const response = await request.post("/api/auth/sign-in/social", {
			data: { provider: "github", callbackURL: "/dashboard" },
			headers: { Origin: origin },
		});

		expect(response.status()).toBeLessThan(500);

		const location = response.headers().location ?? "";
		const body = await response.text();
		const redirectSurface = `${location}\n${body}`;

		expect(redirectSurface).toContain("github.com/login/oauth/authorize");
		expect(redirectSurface).not.toContain("localhost:3000");
		expect(redirectSurface).not.toContain("http://localhost");
	});
});
