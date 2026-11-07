/*
 * Drives the /dev/terminal-vt spike harness (#1846) in headless Chromium and
 * writes the evidence the ADR cites: pane screenshots of the recorded fixture,
 * the synthetic input matrix, stress-stream frame costs per renderer, real IME
 * composition through CDP, and — when --ws points at a local ttyd — a live
 * shell exercising scrollback, selection+copy and resize.
 *
 *   node scripts/terminal-vt-spike.mjs --url http://localhost:3146 --out output/terminal-vt \
 *     [--ws ws://127.0.0.1:7681/ws] [--runs 3] [--mb 2] [--chunks 16384,131072]
 */
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { chromium } from "@playwright/test";

const { values: args } = parseArgs({
	options: {
		url: { type: "string", default: "http://localhost:3146" },
		out: { type: "string", default: "output/terminal-vt" },
		ws: { type: "string" },
		runs: { type: "string", default: "3" },
		mb: { type: "string", default: "2" },
		chunks: { type: "string", default: "16384,131072" },
	},
});

const out = args.out;
await mkdir(out, { recursive: true });
const report = { url: args.url, at: new Date().toISOString(), stress: [], chromium: "" };

const browser = await chromium.launch();
report.chromium = browser.version();
const context = await browser.newContext({
	viewport: { width: 1360, height: 1100 },
	deviceScaleFactor: 2,
	permissions: ["clipboard-read", "clipboard-write"],
});
const page = await context.newPage();

await page.goto(`${args.url}/sign-in`);
await page.getByRole("button", { name: /test bypass/ }).click();
await page.waitForURL((u) => !u.pathname.startsWith("/sign-in"));

async function open(query) {
	await page.goto(`${args.url}/dev/terminal-vt?${query}`);
	await page.waitForFunction(
		() => {
			const text = document.getElementById("spike-metrics")?.textContent ?? "";
			return /"phase": "(done|live|error)"/.test(text);
		},
		null,
		{ timeout: 180_000 },
	);
	return JSON.parse(await page.locator("#spike-metrics").textContent());
}

async function panes(name) {
	await page.getByTestId("pane-web").screenshot({ path: join(out, `${name}-ghostty-web.png`) });
	await page.getByTestId("pane-vt").screenshot({ path: join(out, `${name}-ghostty-vt.png`) });
}

console.log("fixture");
report.fixture = await open("source=fixture");
await panes("fixture");

console.log("input matrix");
await page.getByTestId("run-matrix").click();
await page.getByTestId("matrix").waitFor();
report.matrix = JSON.parse(await page.locator("#spike-metrics").textContent()).matrix;
await page.getByTestId("matrix").screenshot({ path: join(out, "input-matrix.png") });

console.log("stress");
for (const chunk of args.chunks.split(",").map(Number)) {
	for (let run = 0; run < Number(args.runs); run++) {
		for (const [pane, build] of [["web", "fast"], ["vt", "fast"], ["vt", "small"]]) {
			const metrics = await open(`source=stress&pane=${pane}&build=${build}&mb=${args.mb}&chunk=${chunk}`);
			report.stress.push({ run, pane, build, ...metrics });
			console.log(
				`  chunk ${chunk} run ${run} ${pane}/${build}: drain ${metrics.drainMs} ms, interval p95 ${metrics.frameIntervalMs.p95} ms, write p95 ${metrics.writeMs.p95} ms`,
			);
		}
	}
}
await open(`source=stress&pane=both&mb=0.25`);
await panes("stress-tail");

console.log("ime");
report.ime = {};
await open("source=mock");
const cdp = await context.newCDPSession(page);
for (const testId of ["pane-web", "pane-vt"]) {
	await page.getByTestId(testId).click();
	await page.keyboard.type("echo ");
	await cdp.send("Input.imeSetComposition", { text: "にほん", selectionStart: 3, selectionEnd: 3 });
	await cdp.send("Input.imeSetComposition", { text: "日本", selectionStart: 2, selectionEnd: 2 });
	await cdp.send("Input.insertText", { text: "日本" });
	await page.keyboard.press("Enter");
	await page.waitForTimeout(150);
}
await panes("ime-mock");
report.ime.note = "typed `echo ` then committed 日本 through CDP Input.imeSetComposition + insertText, then Enter, into each pane in turn; both panes show the shared mock PTY output";

if (args.ws) {
	console.log("ttyd");
	report.ttyd = await open(`source=ttyd&pane=both&ws=${encodeURIComponent(args.ws)}`);
	await page.waitForTimeout(800);
	const vt = page.getByTestId("pane-vt");
	await vt.click();
	await page.keyboard.type("printf '\\e[1;32mlive\\e[0m \\e[38;2;120;200;255mttyd\\e[0m 完成\\n'; seq 1 300\n");
	await page.waitForTimeout(800);
	await panes("ttyd-live");

	const box = await vt.boundingBox();
	await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
	await page.mouse.wheel(0, -1200);
	await page.waitForTimeout(300);
	await vt.screenshot({ path: join(out, "ttyd-scrollback-ghostty-vt.png") });
	await page.getByTestId("pane-web").hover();
	await page.mouse.wheel(0, -1200);
	await page.waitForTimeout(300);
	await page.getByTestId("pane-web").screenshot({ path: join(out, "ttyd-scrollback-ghostty-web.png") });

	await vt.click();
	await page.keyboard.press("Control+L");
	await page.keyboard.type("echo select-me-please\n");
	await page.waitForTimeout(400);
	await page.mouse.dblclick(box.x + 4 + 7.8 * 8, box.y + 4 + 16 * 1 + 8);
	await page.keyboard.press("Meta+C");
	await page.waitForTimeout(200);
	report.ttydCopy = { "ghostty-vt": await page.evaluate(() => navigator.clipboard.readText()) };
	await vt.screenshot({ path: join(out, "ttyd-selection-ghostty-vt.png") });

	await page.evaluate(() => {
		document.querySelector('[data-testid="pane-vt"]').style.width = "420px";
	});
	await page.waitForTimeout(400);
	await vt.click();
	await page.keyboard.type("stty size; seq -s ' ' 1 40\n");
	await page.waitForTimeout(500);
	await vt.screenshot({ path: join(out, "ttyd-resize-ghostty-vt.png") });
}

await writeFile(join(out, "report.json"), JSON.stringify(report, null, 2));
await browser.close();
console.log(`wrote ${out}/report.json`);
