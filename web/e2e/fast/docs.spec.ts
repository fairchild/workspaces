import { expect, test } from "@playwright/test";

test.describe("Public docs", () => {
	test("serves /docs without authentication", async ({ request }) => {
		const response = await request.get("/docs", { maxRedirects: 0 });
		expect(response.status()).toBe(307);
		expect(response.headers().location).toBe("/docs/index.html");

		const landing = await request.get("/docs/index.html");
		expect(landing.ok()).toBe(true);
		await expect(landing.text()).resolves.toContain(
			"Terminal-first control for your code portfolio.",
		);
	});

	test("renders a Markdown document from the landing page", async ({ page }) => {
		await page.goto("/docs/index.html");
		await page
			.getByRole("link", { name: /Product Overview/ })
			.first()
			.click();

		await expect(page).toHaveURL(/\/docs\/product_overview$/);
		await expect(
			page.getByRole("heading", { name: "WorkSpaces — Product Overview" }),
		).toBeVisible();
		await expect(page.getByText("Repository").first()).toBeVisible();
	});

	test("renders README reference-style images", async ({ page }) => {
		await page.goto("/docs/README");

		const screenshot = page.getByRole("img", { name: "WorkSpaces main window" });
		await expect(screenshot).toBeVisible();
		await expect(screenshot).toHaveAttribute(
			"src",
			"/docs/assets/screenshot-main.jpg",
		);
		await expect(page.locator("#content")).not.toContainText("[screenshot-main]");
	});

	test("shows related docs inline from concept chips", async ({ page }) => {
		await page.goto("/docs/product_overview");

		await page.getByRole("button", { name: "Repository" }).click();

		await expect(
			page.locator("#topic-panel").getByRole("heading", {
				name: "Related to Repository",
			}),
		).toBeVisible();
		await expect(
			page.locator("#topic-panel").getByRole("link", { name: /Vocabulary/ }),
		).toBeVisible();
		await expect(page.getByRole("heading", { name: "In Product" })).toBeVisible();
		await expect(page.getByRole("heading", { name: "Related to Repository" })).toHaveCount(1);
	});

	test("explains concepts in the chip panel", async ({ page }) => {
		await page.goto("/docs/development/lume-integration");

		await expect(page.getByRole("button", { name: "WorkSpaces" })).toHaveCount(0);
		await page.getByRole("button", { name: "Workspace" }).click();

		await expect(page.locator("#topic-panel")).toContainText(
			"An isolated working copy or provider-backed environment",
		);
		await expect(page.locator("#topic-panel .topic-links a").first()).toBeVisible();
	});

	test("shows navigable breadcrumbs for document groups", async ({ page }) => {
		await page.goto("/docs/daytona-vm");

		await expect(page.getByLabel("Documentation breadcrumb")).toContainText(
			"Architecture",
		);
		await expect(
			page.getByLabel("Documentation breadcrumb").getByRole("link", {
				name: "Architecture",
			}),
		).toHaveAttribute("href", /\/docs\/#group-architecture|\/docs\/developer-operator-index\.html\?group=Architecture/);
	});

	test("only shows concept chips that link to related docs", async ({ page }) => {
		await page.goto("/docs/product_overview");

		await expect(page.locator("#concept-map button.chip").first()).toBeVisible();
		const counts = await page
			.locator("#concept-map button.chip")
			.evaluateAll((buttons) =>
				buttons.map((button) =>
					Number(button.getAttribute("data-related-count") || "0"),
				),
			);

		expect(counts.length).toBeGreaterThan(0);
		expect(counts.every((count) => count > 0)).toBe(true);
	});

	test("shows useful same-group docs by default", async ({ page }) => {
		await page.goto("/docs/performance/dashboard");

		await expect(page.getByRole("heading", { name: "In Evidence" })).toBeVisible();
		await expect(
			page.locator("#related-docs").getByRole("link", { name: /Metrics Reference/ }),
		).toBeVisible();
		await expect(page.getByRole("heading", { name: "Quick Docs" })).toHaveCount(0);
	});

	test("shows friendly page metadata before exact details", async ({ page }) => {
		await page.goto("/docs/performance/dashboard");

		await expect(page.locator("#doc-updated")).toHaveText("Updated Mar 22, 2026");
		await expect(page.locator("#doc-updated")).not.toContainText(
			"2026-03-22T10:29:08-0700",
		);
		await expect(page.getByText("Document details")).toHaveCount(0);
		await expect(page.locator("#content")).not.toContainText("Last updated:");
	});

	test("serves suffixed Markdown docs as raw Markdown", async ({ request }) => {
		const response = await request.get("/docs/product_overview.md");

		expect(response.ok()).toBe(true);
		expect(response.headers()["content-type"]).toContain("text/markdown");
		await expect(response.text()).resolves.toMatch(
			/^# WorkSpaces — Product Overview/,
		);
	});

	test("renders extensionless nested docs paths", async ({ page }) => {
		await page.goto("/docs/development/libghostty-integration");

		await expect(
			page.getByRole("heading", { name: "libghostty Integration Guide" }),
		).toBeVisible();
	});

	test("does not render Markdown outside the curated manifest", async ({ page }) => {
		const localManifest = await page.request.get("/docs/local-docs-manifest.json");
		test.skip(localManifest.ok(), "local docs mode intentionally renders all docs");

		await page.goto("/docs/design/product_overview");

		await expect(
			page.getByRole("heading", { name: "Document not published" }),
		).toBeVisible();
		await expect(page.getByText("outside the curated native WorkSpaces docs set")).toBeVisible();
	});

	test("public docs do not expose the local operator index", async ({ request }) => {
		const localManifest = await request.get("/docs/local-docs-manifest.json");
		test.skip(localManifest.ok(), "local docs mode intentionally exposes the operator index");

		const response = await request.get("/docs/developer-operator-index.html");
		expect(response.status()).toBe(404);
	});

	test("local operator index exposes uncurated docs when local mode is active", async ({
		page,
	}) => {
		const localManifest = await page.request.get("/docs/local-docs-manifest.json");
		test.skip(!localManifest.ok(), "public docs mode intentionally excludes the local index");

		await page.goto("/docs/developer-operator-index.html?group=Development");

		await expect(
			page.getByRole("heading", { name: "Operator Index" }),
		).toBeVisible();
		await expect(page.getByRole("link", { name: /Agent Team/ })).toBeVisible();
		await page.getByRole("link", { name: /Agent Team/ }).click();
		await expect(page).toHaveURL(/\/docs\/development\/agent-team$/);
		await expect(page.getByRole("heading", { name: /Agent Team/ })).toBeVisible();
	});
});
