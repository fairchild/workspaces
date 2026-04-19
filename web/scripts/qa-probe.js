import fs from "node:fs/promises";
import path from "node:path";
import AxeBuilder from "@axe-core/playwright";
import { chromium } from "@playwright/test";

const REPO_ROOT = path.resolve(
	process.cwd(),
	process.cwd().endsWith("/web") ? ".." : ".",
);
const DATE = new Date().toISOString().slice(0, 10);
const SLUG = process.env.QA_SLUG ?? "a11y-primary-pages";
const OUT = path.join(REPO_ROOT, "output/qa-agent", DATE, SLUG);
await fs.mkdir(OUT, { recursive: true });

const BASE = process.env.QA_BASE_URL ?? "http://localhost:4000";

const browser = await chromium.launch();
const context = await browser.newContext({
	viewport: { width: 1440, height: 900 },
});

for (const page of [
	{ slug: "landing", url: `${BASE}/` },
	{ slug: "dashboard", url: `${BASE}/dashboard/fairchild/workspaces` },
]) {
	const p = await context.newPage();
	await p.goto(page.url, { waitUntil: "networkidle" });
	await p.screenshot({
		path: path.join(OUT, `${page.slug}.png`),
		fullPage: true,
	});
	const result = await new AxeBuilder({ page: p }).analyze();
	const summary = {
		url: page.url,
		viewport: "1440x900",
		counts: {
			critical: result.violations.filter((v) => v.impact === "critical").length,
			serious: result.violations.filter((v) => v.impact === "serious").length,
			moderate: result.violations.filter((v) => v.impact === "moderate").length,
			minor: result.violations.filter((v) => v.impact === "minor").length,
		},
		violations: result.violations.map((v) => ({
			id: v.id,
			impact: v.impact,
			help: v.help,
			helpUrl: v.helpUrl,
			nodes: v.nodes
				.slice(0, 3)
				.map((n) => ({ target: n.target, html: n.html.slice(0, 200) })),
		})),
	};
	await fs.writeFile(
		path.join(OUT, `${page.slug}-axe.json`),
		JSON.stringify(summary, null, 2),
	);
	console.log(`${page.slug}: ${JSON.stringify(summary.counts)}`);
}

console.log(`\nEvidence root: ${OUT}`);
await browser.close();
