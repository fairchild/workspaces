import { expect, request, test } from "@playwright/test";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
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

function writeFakeClaude(dir: string): string {
	const fakeClaude = path.join(dir, "claude");
	writeFileSync(
		fakeClaude,
		`#!/usr/bin/env node
setTimeout(() => {
console.log(JSON.stringify({
	type: "result",
	session_id: "playwright-docs-fake-claude",
	total_cost_usd: 0,
	result: JSON.stringify({
		answer_markdown: "The docs server renders extensionless paths and keeps raw Markdown at .md URLs.",
		copy_text: "The docs server renders extensionless paths and keeps raw Markdown at .md URLs.",
		citations: [{
			title: "WorkSpaces Docs Site",
			url: "/docs/docs-site",
			source: "docs/README.md",
			snippet: "Rendered and raw Markdown URL contracts."
		}]
	})
}));
}, 250);
`,
		{ mode: 0o755 },
	);
	return fakeClaude;
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
	const fakeClaude = writeFakeClaude(tempDir);
	const port = await freePort();
	baseURL = `http://127.0.0.1:${port}`;
	server = spawn("python3", ["docs/server.py", "--port", String(port)], {
		cwd: repoRoot,
		env: {
			...process.env,
			PYTHONPYCACHEPREFIX: path.join(tempDir, "pycache"),
			WORKSPACES_DOCS_ASK_CLAUDE_BIN: fakeClaude,
			WORKSPACES_DOCS_ASK_TIMEOUT_SECONDS: "10",
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

	test("filters locally and asks Claude Code from the operator index", async ({
		page,
		context,
	}) => {
		await context.grantPermissions(["clipboard-read", "clipboard-write"], {
			origin: baseURL,
		});
		await page.goto(`${baseURL}/docs/developer-operator-index.html`);

		const routeInput = page.locator("#route-input");
		await expect(routeInput).toBeFocused();
		await expect(page.locator("#stats")).toContainText(/\d+ indexed/);
		await routeInput.pressSequentially("lum failng");

		await expect(page.locator("#autocomplete")).toBeVisible();
		await expect(page.locator("#autocomplete .autocomplete-row").first()).toBeVisible();
		await expect(page.locator("#stats")).toContainText(/\d+ shown/);

		await page.locator("#ask-button").click();
		await expect(page.locator("#ai-answer")).toHaveClass(/active/);
		await expect(
			page.locator("#route-form + #ai-answer + #search-hint + #autocomplete"),
		).toHaveCount(1);
		await expect(page.locator("#ask-button")).toBeDisabled();
		await expect(page.locator(".answer-loading")).toBeVisible();
		await expect(page.locator("#ai-answer-body")).toContainText(
			"extensionless paths",
		);
		await expect(page.locator("#ai-answer-body")).not.toContainText(
			"answer_markdown",
		);
		await expect(page.locator("#citation-list a")).toHaveAttribute(
			"href",
			"/docs/docs-site",
		);

		await page.locator("#copy-answer").click();
		await expect(page.locator("#ai-answer-status")).toHaveText("Copied");
	});
});
