/*
 * Perf harness runner: executes the measurable scenarios in contract.json
 * against a production build, writes perf/results.json + results.md, and
 * exits non-zero when a measured metric exceeds its budget. Pending
 * scenarios (surfaces not built yet) are reported, never failed.
 *
 * Deployed-target mode (`--url <origin>` or `--env prod`, resolved the same
 * way as scripts/validate.mjs): every contract scenario needs the
 * auth-bypass cookie plus locally seeded fixtures, so against a real
 * deployment they're reported skipped rather than measured or failed. The
 * one honest, credential-free measurement is the /sign-in entry route's
 * LCP/TBT. Deployed results are report-only (perf/results-deployed.json +
 * .md) and never fail the run — see docs/perf-floor.md.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync, execSync } from "node:child_process";
import path from "node:path";
import { gzipSync } from "node:zlib";
import {
	bypassServerEnv,
	connectSeedClient,
	launchChromium,
	startProductionServer,
	testAuthCookie,
	WEB_NEXT_ROOT,
} from "../scripts/harness.mjs";
import { detectSsoWall, resolveTarget } from "../scripts/validate-core.mjs";
import { buildDeployedResults, deployedResultsToMarkdown } from "./deployed-core.mjs";

const PERF_DIR = path.join(WEB_NEXT_ROOT, "perf");
const PORT = Number(process.env.PERF_PORT ?? 3100);
const TURN_TIMEOUT_MS = 20_000;
// Time to keep observing after load so late long tasks and LCP updates land.
const ROUTE_SETTLE_MS = 1500;

// resume_latency_100: one seeded session per run, each an interrupted turn
// whose last event carries this marker (its paint means "caught up").
const RESUME_SESSION_PREFIX = "perf-resume-";
const RESUME_MARKER = "RESUME_CAUGHT_UP";
const RESUME_EVENT_COUNT = 100;

const contract = JSON.parse(
	readFileSync(path.join(PERF_DIR, "contract.json"), "utf8"),
);

// --- stats ---------------------------------------------------------------

function median(samples) {
	const sorted = [...samples].sort((a, b) => a - b);
	const mid = Math.floor(sorted.length / 2);
	return sorted.length % 2
		? sorted[mid]
		: (sorted[mid - 1] + sorted[mid]) / 2;
}

function aggregate(stat, samples) {
	if (stat === "median") return median(samples);
	if (stat === "max") return Math.max(...samples);
	if (stat === "exact") return samples[0];
	throw new Error(`Unknown stat: ${stat}`);
}

// --- first-load JS from the build manifests -------------------------------
// Same basis as `next build`'s First Load JS column: gzipped size of the
// route's client chunks (shared root chunks + layouts + page). Manifest keys
// carry route groups ("/(app)/sessions/[id]/page"); scenarios name routes by
// URL path, so keys are matched with groups stripped.

function stripRouteGroups(key) {
	return key.replace(/\/\([^)]+\)/g, "") || "/";
}

function firstLoadJsKb(route) {
	const nextDir = path.join(WEB_NEXT_ROOT, ".next");
	const buildManifest = JSON.parse(
		readFileSync(path.join(nextDir, "build-manifest.json"), "utf8"),
	);
	const appManifest = JSON.parse(
		readFileSync(path.join(nextDir, "app-build-manifest.json"), "utf8"),
	);
	const routeKey = route === "/" ? "/page" : `${route}/page`;
	const appliesToRoute = (key) => {
		const stripped = stripRouteGroups(key);
		if (stripped === routeKey) return true; // the page itself
		if (!stripped.endsWith("/layout")) return false;
		// A layout applies when the route sits under its segment path.
		const layoutDir = stripped.slice(0, -"layout".length);
		return routeKey.startsWith(layoutDir);
	};
	const files = new Set(
		Object.entries(appManifest.pages)
			.filter(([key]) => appliesToRoute(key))
			.flatMap(([, chunkFiles]) => chunkFiles)
			.concat(buildManifest.rootMainFiles ?? [])
			.filter((file) => file.endsWith(".js")),
	);
	let bytes = 0;
	for (const file of files) {
		bytes += gzipSync(readFileSync(path.join(nextDir, file))).length;
	}
	return bytes / 1024;
}

// --- in-page helpers -------------------------------------------------------

/** A cold, signed-in context (routes are behind auth — see contract note). */
async function newSignedInContext(browser, baseUrl) {
	const context = await browser.newContext({ baseURL: baseUrl });
	await context.addCookies([testAuthCookie(baseUrl)]);
	return context;
}

async function openSession(browser, baseUrl, sessionId) {
	const context = await newSignedInContext(browser, baseUrl);
	const page = await context.newPage();
	await page.goto(`/sessions/${sessionId}`, { waitUntil: "networkidle" });
	return { context, page };
}

async function sendSessionMessage(page, text) {
	const compose = 'input[aria-label="Reply to Claude"]';
	await page.fill(compose, text);
	await page.press(compose, "Enter");
}

/** The turn is complete when its receipt (end-of-turn stats) is rendered. */
function waitForTurnComplete(page) {
	return page.waitForFunction(
		() => document.querySelector('[data-testid="turn-stats"]') !== null,
		undefined,
		{ timeout: TURN_TIMEOUT_MS },
	);
}

// --- scenario implementations ---------------------------------------------
// Each returns { metricName: [samples...] }.

// Turn scenarios run on fresh seeded sessions (perf-turn-N / perf-cadence-N,
// one per run) so transcript growth from one run never colors the next.

async function runTtftMock(browser, baseUrl, runs) {
	const samples = [];
	for (let i = 0; i < runs; i++) {
		const { context, page } = await openSession(browser, baseUrl, `perf-turn-${i}`);
		const start = Date.now();
		await sendSessionMessage(page, "Measure time to first token");
		// waitForFunction polls on rAF, so this resolves on the frame after
		// the first assistant text part renders — "first token painted".
		await page.waitForFunction(
			() => {
				const text = document.querySelector(
					'[data-message-role="assistant"] p',
				)?.textContent;
				return (text ?? "").trim().length > 0;
			},
			undefined,
			{ timeout: TURN_TIMEOUT_MS },
		);
		samples.push(Date.now() - start);
		await context.close();
	}
	return { ttft_ms: samples };
}

async function runStreamingCadence(browser, baseUrl, runs) {
	const samples = [];
	for (let i = 0; i < runs; i++) {
		const { context, page } = await openSession(
			browser,
			baseUrl,
			`perf-cadence-${i}`,
		);
		await page.evaluate(() => {
			window.__longTasks = [];
			new PerformanceObserver((list) => {
				for (const entry of list.getEntries())
					window.__longTasks.push(entry.duration);
			}).observe({ type: "longtask" });
		});
		await sendSessionMessage(page, "Measure streaming cadence");
		await waitForTurnComplete(page);
		samples.push(
			await page.evaluate(() => Math.max(0, ...window.__longTasks)),
		);
		await context.close();
	}
	return { longest_task_ms: samples };
}

// Shared LCP + long-task instrumentation for a cold navigation, used by both
// the authenticated route scenarios and the deployed-target entry-route
// measurement (which has no signed-in context to attach to).
async function measurePageLoad(page, route) {
	await page.addInitScript(() => {
		window.__routePerf = { lcp: 0, longTasks: [] };
		new PerformanceObserver((list) => {
			const entries = list.getEntries();
			if (entries.length > 0)
				window.__routePerf.lcp = entries[entries.length - 1].startTime;
		}).observe({ type: "largest-contentful-paint", buffered: true });
		new PerformanceObserver((list) => {
			for (const entry of list.getEntries())
				window.__routePerf.longTasks.push(entry.duration);
		}).observe({ type: "longtask", buffered: true });
	});
	await page.goto(route, { waitUntil: "networkidle" });
	await page.waitForTimeout(ROUTE_SETTLE_MS);
	const { lcp, longTasks } = await page.evaluate(() => window.__routePerf);
	return {
		lcp,
		tbt: longTasks.reduce((total, duration) => total + Math.max(0, duration - 50), 0),
	};
}

// `scenario.manifest_route` maps a concrete URL (e.g. /sessions/perf-empty)
// to its build-manifest route (/sessions/[id]) for the first-load-JS lookup.
async function runRoute(browser, baseUrl, scenario) {
	const { route, runs } = scenario;
	const lcpSamples = [];
	const tbtSamples = [];
	for (let i = 0; i < runs; i++) {
		const context = await newSignedInContext(browser, baseUrl);
		const page = await context.newPage();
		const { lcp, tbt } = await measurePageLoad(page, route);
		lcpSamples.push(lcp);
		tbtSamples.push(tbt);
		await context.close();
	}
	return {
		lcp_ms: lcpSamples,
		tbt_ms: tbtSamples,
		first_load_js_kb: [firstLoadJsKb(scenario.manifest_route ?? route)],
	};
}

// Reconnect-to-caught-up for an interrupted turn: navigate to a session whose
// ~100-event assistant turn was left in flight (seeded stale, no `done`), so
// the client resumes it — the tail route closes the abandoned turn and
// backfills the whole log. Time from navigation start until the turn's last
// event (a marker) is painted, on a cold context per run.
async function runResumeLatency(browser, baseUrl, scenario) {
	const samples = [];
	for (let i = 0; i < scenario.runs; i++) {
		const context = await newSignedInContext(browser, baseUrl);
		const page = await context.newPage();
		await page.goto(`/sessions/${RESUME_SESSION_PREFIX}${i}`, {
			waitUntil: "commit",
		});
		await page.waitForFunction(
			(marker) => document.body.innerText.includes(marker),
			RESUME_MARKER,
			{ timeout: TURN_TIMEOUT_MS },
		);
		samples.push(await page.evaluate(() => performance.now()));
		await context.close();
	}
	return { resume_ms: samples };
}

// Time from navigation start until every seeded message is present in a
// painted frame (waitForFunction polls on rAF; performance.now() is relative
// to navigationStart), on a cold context per run.
async function runTranscriptRender(browser, baseUrl, route, runs) {
	const messageCount = Number(new URL(route, baseUrl).searchParams.get("seed"));
	const samples = [];
	for (let i = 0; i < runs; i++) {
		const context = await newSignedInContext(browser, baseUrl);
		const page = await context.newPage();
		await page.goto(route, { waitUntil: "commit" });
		await page.waitForFunction(
			(count) =>
				document.querySelectorAll("[data-message-role]").length >= count,
			messageCount,
			{ timeout: TURN_TIMEOUT_MS },
		);
		samples.push(await page.evaluate(() => performance.now()));
		await context.close();
	}
	return { initial_render_ms: samples };
}

// In-process (no browser): shells out to the tsx bench and reads its JSON
// samples. Kept a subprocess so run.mjs itself stays plain Node/ESM while the
// bench imports the TypeScript projection under tsx.
function runProjectionBench(scenario) {
	const stdout = execFileSync(
		"pnpm",
		["exec", "tsx", "perf/projection-bench.mjs", String(scenario.runs)],
		{ cwd: WEB_NEXT_ROOT, encoding: "utf8" },
	);
	const lastLine = stdout.trim().split("\n").at(-1);
	const { samples } = JSON.parse(lastLine);
	return { projection_ms: samples };
}

const SCENARIO_RUNNERS = {
	ttft_mock: (browser, baseUrl, scenario) =>
		runTtftMock(browser, baseUrl, scenario.runs),
	streaming_cadence: (browser, baseUrl, scenario) =>
		runStreamingCadence(browser, baseUrl, scenario.runs),
	resume_latency_100: runResumeLatency,
	transcript_render_200: (browser, baseUrl, scenario) =>
		runTranscriptRender(browser, baseUrl, scenario.route, scenario.runs),
	projection_200: (browser, baseUrl, scenario) => runProjectionBench(scenario),
	route_home: runRoute,
	route_session_empty: runRoute,
	route_sessions_demo: runRoute,
};

// --- reporting -------------------------------------------------------------

function round(value) {
	return Math.round(value * 10) / 10;
}

function toMarkdown(results) {
	const lines = [
		"| Scenario | Metric | Stat | Value | Budget | Status |",
		"|---|---|---|---|---|---|",
	];
	for (const scenario of results.scenarios) {
		if (scenario.status === "pending") {
			lines.push(
				`| ${scenario.id} | — | — | — | — | pending (${scenario.reason}) |`,
			);
			continue;
		}
		for (const [name, metric] of Object.entries(scenario.metrics)) {
			lines.push(
				`| ${scenario.id} | ${name} | ${metric.stat} | ${round(metric.value)} | ${metric.budget} | ${metric.pass ? "pass" : "FAIL"} |`,
			);
		}
	}
	return lines.join("\n");
}

// --- deployed-target mode ----------------------------------------------------
// No production server spawn, no DB seeding, no signed-in context — those
// only exist locally. Every contract scenario is reported skipped; the one
// honest measurement is the /sign-in entry route's LCP/TBT.

const PROBE_TIMEOUT_MS = 15_000;

/** A redirect-preserving, never-throwing fetch — same shape as validate.mjs's probe. */
async function probe(baseUrl, pathname) {
	const bypass = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;
	try {
		const res = await fetch(`${baseUrl}${pathname}`, {
			headers: bypass ? { "x-vercel-protection-bypass": bypass } : {},
			redirect: "manual",
			signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
		});
		return { status: res.status, location: res.headers.get("location") ?? undefined };
	} catch (error) {
		return { status: 0, location: undefined, error: String(error) };
	}
}

async function measureDeployedEntry(baseUrl) {
	const signInProbe = await probe(baseUrl, "/sign-in");
	if (detectSsoWall(signInProbe)) {
		return {
			id: "deployed_entry_signin",
			status: "skipped",
			reason:
				"Vercel deployment protection (SSO) — set VERCEL_AUTOMATION_BYPASS_SECRET to measure this target (#814)",
		};
	}
	if (signInProbe.status !== 200) {
		return {
			id: "deployed_entry_signin",
			status: "skipped",
			reason: `GET ${baseUrl}/sign-in → ${signInProbe.status || signInProbe.error} (not reachable)`,
		};
	}
	const browser = await launchChromium();
	try {
		const page = await (await browser.newContext({ baseURL: baseUrl })).newPage();
		const { lcp, tbt } = await measurePageLoad(page, "/sign-in");
		return {
			id: "deployed_entry_signin",
			status: "measured",
			route: "/sign-in",
			metrics: {
				lcp_ms: { value: round(lcp) },
				tbt_ms: { value: round(tbt) },
			},
		};
	} finally {
		await browser.close();
	}
}

async function runDeployedMode(target) {
	console.log(`deployed-target perf run: ${target.envName} — ${target.baseUrl}\n`);
	const commit = execSync("git rev-parse --short HEAD", { cwd: WEB_NEXT_ROOT }).toString().trim();
	const entry = await measureDeployedEntry(target.baseUrl);
	const results = buildDeployedResults({ target, commit, contract, entry });
	const markdown = deployedResultsToMarkdown(results);
	writeFileSync(
		path.join(PERF_DIR, "results-deployed.json"),
		`${JSON.stringify(results, null, "\t")}\n`,
	);
	writeFileSync(path.join(PERF_DIR, "results-deployed.md"), `${markdown}\n`);
	console.log(`\n${markdown}\n`);
	console.log(
		"results written to perf/results-deployed.json and perf/results-deployed.md (report-only — never fails the run)",
	);
}

// --- local suite -------------------------------------------------------------

async function runLocalSuite() {
	const results = {
		date: new Date().toISOString(),
		commit: execSync("git rev-parse --short HEAD", {
			cwd: WEB_NEXT_ROOT,
		})
			.toString()
			.trim(),
		scenarios: [],
	};
	let failed = false;

	const { env, databaseUrl } = bypassServerEnv("perf-db");
	const server = await startProductionServer(PORT, env);
	// Seed the fixed rows the scenarios navigate to: one repo, one empty
	// session at a stable id, and one fresh session per turn-scenario run.
	const db = await connectSeedClient(server.baseUrl, databaseUrl);
	const now = new Date().toISOString();
	await db.execute({
		sql: "INSERT INTO repos (id, full_name, default_branch, created_at) VALUES (?, ?, 'main', ?)",
		args: ["fairchild/workspaces", "fairchild/workspaces", now],
	});
	const seedSession = (id) =>
		db.execute({
			sql: `INSERT INTO sessions
				(id, repo_id, title, provider, status, claude_session_id, created_at, last_activity_at)
				VALUES (?, 'fairchild/workspaces', '', 'mock', 'active', NULL, ?, ?)`,
			args: [id, now, now],
		});
	// A ~100-event assistant turn with no `done`, backdated so it reads as
	// stale (an interrupted turn). seq 1 is the user prompt; seq 2..N are
	// assistant text deltas, the last carrying the caught-up marker.
	const seedInterruptedTurn = async (db, id) => {
		const old = new Date(Date.now() - 60_000).toISOString();
		const event = (seq, role, chunk) =>
			db.execute({
				sql: `INSERT INTO session_events (session_id, seq, role, kind, payload, created_at)
					VALUES (?, ?, ?, ?, ?, ?)`,
				args: [id, seq, role, chunk.type, JSON.stringify(chunk), old],
			});
		await event(1, "user", { type: "text", content: "Resume a long turn" });
		for (let seq = 2; seq < RESUME_EVENT_COUNT; seq++) {
			await event(seq, "assistant", { type: "text", content: `token${seq} ` });
		}
		await event(RESUME_EVENT_COUNT, "assistant", {
			type: "text",
			content: RESUME_MARKER,
		});
	};
	await seedSession("perf-empty");
	const runsOf = (id) =>
		contract.scenarios.find((scenario) => scenario.id === id)?.runs ?? 0;
	for (let i = 0; i < runsOf("ttft_mock"); i++) {
		await seedSession(`perf-turn-${i}`);
	}
	for (let i = 0; i < runsOf("streaming_cadence"); i++) {
		await seedSession(`perf-cadence-${i}`);
	}
	// resume_latency_100: one interrupted turn per run. Each is a ~100-event
	// assistant turn with NO `done` and a backdated clock, so resolveTurn reads
	// it as stale and the client resumes it on load.
	for (let i = 0; i < runsOf("resume_latency_100"); i++) {
		const id = `${RESUME_SESSION_PREFIX}${i}`;
		await seedSession(id);
		await seedInterruptedTurn(db, id);
	}
	db.close();

	const browser = await launchChromium();
	try {
		for (const scenario of contract.scenarios) {
			if (scenario.status === "pending") {
				results.scenarios.push({
					id: scenario.id,
					status: "pending",
					reason: scenario.reason,
				});
				continue;
			}
			const runner = SCENARIO_RUNNERS[scenario.id];
			if (!runner) {
				throw new Error(
					`Scenario "${scenario.id}" is marked measured but has no runner implementation.`,
				);
			}
			console.log(`running ${scenario.id} (${scenario.runs} runs)…`);
			const samplesByMetric = await runner(browser, server.baseUrl, scenario);
			const metrics = {};
			for (const [name, spec] of Object.entries(scenario.metrics)) {
				const samples = samplesByMetric[name];
				const value = aggregate(spec.stat, samples);
				const pass = value <= spec.budget;
				if (!pass) failed = true;
				metrics[name] = {
					stat: spec.stat,
					samples: samples.map(round),
					value: round(value),
					budget: spec.budget,
					pass,
				};
			}
			results.scenarios.push({ id: scenario.id, status: "measured", metrics });
		}
	} finally {
		await browser.close();
		await server.stop();
	}

	const markdown = toMarkdown(results);
	writeFileSync(
		path.join(PERF_DIR, "results.json"),
		`${JSON.stringify(results, null, "\t")}\n`,
	);
	writeFileSync(path.join(PERF_DIR, "results.md"), `${markdown}\n`);
	console.log(`\n${markdown}\n`);
	console.log(`results written to perf/results.json and perf/results.md`);

	if (failed) {
		console.error("PERF BUDGET EXCEEDED — see FAIL rows above.");
		process.exit(1);
	}
}

// --- entry point --------------------------------------------------------------
// No flags (or `--env local`): the full local suite, unchanged, gates on
// contract.json's budgets. `--url <origin>` or `--env prod`: deployed mode,
// report-only. Target resolution mirrors scripts/validate.mjs exactly.

async function main() {
	const target = resolveTarget(process.argv.slice(2), process.env);
	if (target.spawnLocal) {
		await runLocalSuite();
	} else {
		await runDeployedMode(target);
	}
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
