import { expect, request, test } from "@playwright/test";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import net from "node:net";

const repoRoot = path.resolve(import.meta.dirname, "../../..");

let server: ChildProcessWithoutNullStreams | undefined;
let baseURL = "";
let tempDir = "";

test.describe.configure({ mode: "serial" });

async function freePort(): Promise<number> {
	return await new Promise((resolve, reject) => {
		const socket = net.createServer();
		socket.once("error", reject);
		socket.listen(0, "127.0.0.1", () => {
			const address = socket.address();
			socket.close(() => {
				if (typeof address === "object" && address) {
					resolve(address.port);
				} else {
					reject(new Error("Could not allocate a local port."));
				}
			});
		});
	});
}

async function waitForServer(url: string): Promise<void> {
	const context = await request.newContext({ baseURL: url });
	const deadline = Date.now() + 10_000;
	try {
		while (Date.now() < deadline) {
			if (server?.exitCode !== null) {
				throw new Error(`docs server exited early with ${server?.exitCode}`);
			}
			try {
				const response = await context.get("/docs/");
				if (response.ok()) return;
			} catch {
				// Keep polling until the server accepts connections.
			}
			await new Promise((resolve) => setTimeout(resolve, 100));
		}
		throw new Error(`Timed out waiting for ${url}`);
	} finally {
		await context.dispose();
	}
}

test.beforeAll(async () => {
	tempDir = mkdtempSync(path.join(tmpdir(), "workspaces-docs-playwright-"));
	const port = await freePort();
	baseURL = `http://127.0.0.1:${port}`;
	server = spawn("python3", ["docs/server.py", "--port", String(port)], {
		cwd: repoRoot,
		env: {
			...process.env,
			PYTHONPYCACHEPREFIX: path.join(tempDir, "pycache"),
		},
	});
	await waitForServer(baseURL);
});

test.afterAll(async () => {
	if (server && server.exitCode === null) {
		server.kill("SIGTERM");
		await new Promise<void>((resolve) => {
			server?.once("exit", () => resolve());
			setTimeout(resolve, 500);
		});
	}
	if (tempDir) rmSync(tempDir, { recursive: true, force: true });
});

test.describe("Local docs server", () => {
	test("serves raw Markdown, rendered docs, and the local manifest", async () => {
		const context = await request.newContext({ baseURL });
		try {
			const raw = await context.get("/docs/development/libghostty-integration.md");
			expect(raw.ok()).toBe(true);
			expect(raw.headers()["content-type"]).toContain("text/markdown");
			await expect(raw.text()).resolves.toMatch(/^# /);

			const rendered = await context.get(
				"/docs/development/libghostty-integration",
			);
			expect(rendered.ok()).toBe(true);
			expect(rendered.headers()["content-type"]).toContain("text/html");
			await expect(rendered.text()).resolves.toContain("WorkSpaces Docs Reader");

			const manifest = await context.get("/docs/local-docs-manifest.json");
			expect(manifest.ok()).toBe(true);
			const payload = await manifest.json();
			expect(payload.local).toBe(true);
			expect(payload.entries.length).toBeGreaterThanOrEqual(50);
			expect(
				payload.entries.some(
					(entry: { dest?: string }) =>
						entry.dest === "development/agent-team.md",
				),
			).toBe(true);
		} finally {
			await context.dispose();
		}
	});

	test("filters locally from the operator index", async ({ page, context }) => {
		await page.goto(`${baseURL}/docs/developer-operator-index.html`);

		const routeInput = page.locator("#route-input");
		await expect(routeInput).toBeFocused();
		await expect(page.locator("#stats")).toContainText(/\d+ indexed/);
		await routeInput.pressSequentially("lum failng");

		await expect(page.locator("#autocomplete")).toBeVisible();
		await expect(page.locator("#autocomplete .autocomplete-row").first()).toBeVisible();
		await expect(page.locator("#stats")).toContainText(/\d+ shown/);

		const search = await context.request.get(
			`${baseURL}/docs/api/search?q=lum%20failng&limit=5`,
		);
		expect(search.ok()).toBe(true);
		const searchPayload = await search.json();
		expect(searchPayload.results.length).toBeGreaterThan(0);

		const automationSearch = await context.request.get(
			`${baseURL}/docs/api/search?q=tile%20split&limit=5`,
		);
		expect(automationSearch.ok()).toBe(true);
		const automationPayload = await automationSearch.json();
		expect(
			automationPayload.results.some(
				(result: { title?: string }) => result.title === "Automation API Guide",
			),
		).toBe(true);

		await routeInput.press("Enter");
		await expect(page.locator("#autocomplete")).toBeVisible();
		await expect(page.locator("#route-form + #search-hint + #autocomplete")).toHaveCount(
			1,
		);
	});

	test("operator index dives collapse to header and tagline", async ({ page }) => {
		await page.goto(`${baseURL}/docs/developer-operator-index.html`);

		for (const dive of [
			{
				selector: "details.map",
				heading: "System Map",
				tagline: "Reserved for the technical architecture map.",
				inner: ".architecture-prompt",
			},
			{
				selector: "details.routing",
				heading: "Routing Matrix",
				tagline: "Choose the job you are doing now.",
				inner: "#route-grid",
			},
			{
				selector: "details.concept-strip",
				heading: "Concept Clusters",
				tagline: "Follow related terms across the documentation set.",
				inner: "#concept-grid",
			},
			{
				selector: "details.reading-path",
				heading: "Reading Path",
				tagline:
					"Use this when you are onboarding or trying to rebuild the mental model from scratch.",
				inner: "#path-rail",
			},
		]) {
			const section = page.locator(dive.selector);
			await expect(section).toHaveJSProperty("open", true);
			await section.locator("summary").click();
			await expect(section).toHaveJSProperty("open", false);
			await expect(section.getByRole("heading", { name: dive.heading })).toBeVisible();
			await expect(section.getByText(dive.tagline)).toBeVisible();
			await expect(page.locator(dive.inner)).toBeHidden();
		}
	});
});
