/*
 * Environment-targetable validation: `pnpm validate [--env local|prod | --url
 * <origin>]` runs the full staged suite — reachability, the auth/security
 * posture checks, authenticated flows (#814), the per-model gateway sweep
 * (#816), deployed-safe e2e (#817), and one real agentic coding turn (#818,
 * deployed targets; `--skip-real-turn` to opt out of the spend) — against a
 * local spawn or a real deployment, and reports pass/fail/skip per check
 * (JSON + a Markdown report under output/validate/, exit 1 on any failure).
 * Stages needing credentials gate themselves and report `skipped: missing
 * <name>` rather than silently passing.
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { MODEL_OPTIONS } from "../src/lib/agent-runtime/models.ts";
import { realTurnStage } from "./real-turn.mjs";
import {
	authedCookie,
	classifyModelSweepGate,
	detectAuthMode,
	detectSsoWall,
	evaluateAuthedProbe,
	evaluateE2eResults,
	evaluateModelChecks,
	evaluatePosture,
	gateStage,
	isRedirectToSignIn,
	LOCAL_MODE_PORT,
	LOCAL_PORT,
	redactSecrets,
	renderMarkdownReport,
	resolveTarget,
	summarize,
	validationSessionCookieName,
} from "./validate-core.mjs";
import {
	bypassServerEnv,
	localModeServerEnv,
	startProductionServer,
	WEB_NEXT_ROOT,
} from "./harness.mjs";

const PROBE_TIMEOUT_MS = 15_000;

const AUTHED_STAGE_ID = "authenticated flows (#814)";
const MODEL_SWEEP_STAGE_ID = "model sweep (#816)";
const E2E_STAGE_ID = "e2e deployed-safe flows (#817)";
const REAL_TURN_STAGE_ID = "real agentic turn (#818)";

/** A fetch that never follows redirects and never throws on HTTP errors.
 * When VERCEL_AUTOMATION_BYPASS_SECRET is set, every probe carries the
 * standard protection-bypass header so SSO-walled previews open up (#814
 * provisions the secret; this is just the transport). */
async function probe(baseUrl, pathname, init = {}) {
	const method = init.method ?? "GET";
	const bypass = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;
	try {
		const res = await fetch(`${baseUrl}${pathname}`, {
			...init,
			headers: {
				...(bypass ? { "x-vercel-protection-bypass": bypass } : {}),
				...init.headers,
			},
			redirect: "manual",
			signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
		});
		return {
			path: pathname,
			method,
			status: res.status,
			location: res.headers.get("location") ?? undefined,
			body: await res.text().catch(() => ""),
		};
	} catch (error) {
		// A malformed credential can make fetch throw an invalid-header error
		// that echoes the header VALUE — redact both secrets before the message
		// can reach a check detail or the persisted report (codex finding).
		const secrets = [
			process.env.VERCEL_AUTOMATION_BYPASS_SECRET,
			process.env.WEB_NEXT_VALIDATION_SESSION,
		];
		return { path: pathname, method, status: 0, body: redactSecrets(String(error), secrets) };
	}
}

async function probeWithHostHeader(baseUrl, pathname, host) {
	const url = new URL(pathname, baseUrl);
	return new Promise((resolve) => {
		const req = http.request(
			{
				hostname: url.hostname,
				port: url.port,
				path: `${url.pathname}${url.search}`,
				method: "GET",
				headers: { Host: host },
				timeout: PROBE_TIMEOUT_MS,
			},
			(res) => {
				let body = "";
				res.setEncoding("utf8");
				res.on("data", (chunk) => {
					body += chunk;
				});
				res.on("end", () => {
					resolve({
						path: pathname,
						method: "GET",
						status: res.statusCode ?? 0,
						location: res.headers.location,
						body,
					});
				});
			},
		);
		req.on("timeout", () => {
			req.destroy(new Error("request timed out"));
		});
		req.on("error", (error) => {
			resolve({ path: pathname, method: "GET", status: 0, body: String(error) });
		});
		req.end();
	});
}

async function reachabilityStage(baseUrl) {
	const signIn = await probe(baseUrl, "/sign-in");
	if (detectSsoWall(signIn)) {
		// A walled deployment offers nothing to assert without the bypass
		// secret — a credential gate, not an app failure.
		return {
			id: "reachability",
			status: "skip",
			reason:
				"Vercel deployment protection (SSO) — set VERCEL_AUTOMATION_BYPASS_SECRET to validate this target (#814)",
			signIn,
		};
	}
	return {
		id: "reachability",
		status: "run",
		checks: [
			{
				id: "signin_reachable",
				status: signIn.status === 200 ? "pass" : "fail",
				detail: `GET ${baseUrl}/sign-in → ${signIn.status || signIn.body}`,
			},
		],
		signIn,
	};
}

async function postureStage(baseUrl, signIn) {
	const mode = detectAuthMode(signIn.body ?? "");
	const [home, forgedCookieHome, ...api] = await Promise.all([
		probe(baseUrl, "/"),
		probe(baseUrl, "/", { headers: { cookie: "test-auth-login=fairchild" } }),
		probe(baseUrl, "/api/sessions/validation-probe/chat", {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ text: "posture probe" }),
		}),
		probe(baseUrl, "/api/sessions/validation-probe/stream"),
		probe(baseUrl, "/api/diag/gateway"),
	]);
	return {
		id: `posture (${mode} auth)`,
		status: "run",
		checks: evaluatePosture(mode, { home, signIn, forgedCookieHome, api }),
	};
}

async function localModeStage(baseUrl, token) {
	const [badHost, noCookieApi, bypassCookieHome, tokenCookieHome] = await Promise.all([
		probeWithHostHeader(baseUrl, "/api/repos", "spaces.example"),
		probe(baseUrl, "/api/repos"),
		probe(baseUrl, "/", { headers: { cookie: "test-auth-login=fairchild" } }),
		probe(baseUrl, "/", {
			headers: token ? { cookie: `web-next-local-session=${token}` } : {},
		}),
	]);
	return {
		id: "local-mode posture",
		status: "run",
		checks: [
			{
				id: "loopback_host_required",
				status: badHost.status === 403 ? "pass" : "fail",
				detail:
					badHost.status === 403
						? `GET /api/repos with Host: spaces.example → ${badHost.status}`
						: `target is not in local mode: GET /api/repos with Host: spaces.example → ${badHost.status}`,
			},
			{
				id: "token_required",
				status: noCookieApi.status === 401 ? "pass" : "fail",
				detail: `GET /api/repos without cookie → ${noCookieApi.status}`,
			},
			{
				id: "bypass_cookie_inert",
				status: isRedirectToSignIn(bypassCookieHome) ? "pass" : "fail",
				detail: `GET / with test-auth-login cookie → ${bypassCookieHome.status}`,
			},
			{
				id: "local_cookie_authenticates",
				status: tokenCookieHome.status === 200 ? "pass" : "fail",
				detail: `GET / with local session cookie → ${tokenCookieHome.status}`,
			},
		],
	};
}

/**
 * #814's authenticated flows: prove the validation identity can call an
 * auth-gated, data-reading API end to end. Mode-aware — a bypass-mode target
 * authenticates with the test cookie (no credential to gate on); a real-auth
 * target replays the pre-minted validation session and gates on its absence.
 */
async function authenticatedStage(baseUrl, mode, env) {
	const id = AUTHED_STAGE_ID;
	const cookie = authedCookie(mode, baseUrl, env);
	if (!cookie) {
		const gate = gateStage({ WEB_NEXT_VALIDATION_SESSION: env.WEB_NEXT_VALIDATION_SESSION });
		return { id, status: "skip", reason: gate.reason };
	}
	const res = await probe(baseUrl, "/api/repos", { headers: { cookie } });
	if (res.status === 401 || res.status === 403 || isRedirectToSignIn(res)) {
		return { id, status: "skip", reason: "validation session expired — re-seed" };
	}
	return { id, status: "run", checks: evaluateAuthedProbe({ status: res.status, body: safeJson(res.body) }) };
}

function safeJson(text) {
	try {
		return JSON.parse(text);
	} catch {
		return undefined;
	}
}

/**
 * #816: iterates every selectable model (agent-runtime/models.ts — the same
 * set the picker offers) through the auth-gated `/api/diag/gateway`, proving
 * selection actually routes per-model, not just a hardcoded default. Gates
 * on the validation session (needed to call the auth-gated route at all) and
 * — via the first probe's response — on the target actually having
 * AI_GATEWAY_API_KEY, since that can only be observed by asking the
 * deployment itself.
 */
async function modelSweepStage(baseUrl, env) {
	const id = MODEL_SWEEP_STAGE_ID;
	const gate = gateStage({ WEB_NEXT_VALIDATION_SESSION: env.WEB_NEXT_VALIDATION_SESSION });
	if (!gate.runnable) return { id, status: "skip", reason: gate.reason };

	const cookie = `${validationSessionCookieName(baseUrl)}=${env.WEB_NEXT_VALIDATION_SESSION}`;
	const probeModel = (modelId) =>
		probe(baseUrl, `/api/diag/gateway?model=${encodeURIComponent(modelId)}`, { headers: { cookie } });

	const [first, ...rest] = MODEL_OPTIONS;
	const firstProbe = await probeModel(first.id);
	const firstBody = safeJson(firstProbe.body);
	const modelGate = classifyModelSweepGate({ status: firstProbe.status, body: firstBody });
	if (modelGate.skip) return { id, status: "skip", reason: modelGate.reason };

	const restProbes = await Promise.all(rest.map((m) => probeModel(m.id)));
	const results = [
		{ id: first.id, status: firstProbe.status, body: firstBody },
		...rest.map((m, i) => ({ id: m.id, status: restProbes[i].status, body: safeJson(restProbes[i].body) })),
	];
	return { id, status: "run", checks: evaluateModelChecks(results) };
}

/**
 * #817: replays the deployed-safe (`@deployed-safe`-tagged) Playwright specs
 * against the target through `playwright.config.ts`'s deployed project seam
 * (VALIDATE_TARGET_URL / VALIDATE_ENV_NAME), then interprets its JSON report.
 * Gates on the validation session; a redirect-to-sign-in on a plain page
 * fetch with that session's cookie — cheaper than launching a browser to find
 * out — means the session bounced, matching the decision doc's expired-
 * session skip wording.
 */
async function e2eDeployedSafeStage(target, env) {
	const id = E2E_STAGE_ID;
	const gate = gateStage({ WEB_NEXT_VALIDATION_SESSION: env.WEB_NEXT_VALIDATION_SESSION });
	if (!gate.runnable) return { id, status: "skip", reason: gate.reason };

	const cookie = `${validationSessionCookieName(target.baseUrl)}=${env.WEB_NEXT_VALIDATION_SESSION}`;
	const authCheck = await probe(target.baseUrl, "/", { headers: { cookie } });
	if (isRedirectToSignIn(authCheck)) {
		return { id, status: "skip", reason: "validation session expired — re-seed" };
	}

	const jsonOut = path.join(WEB_NEXT_ROOT, "output", "validate", target.envName, "e2e-results.json");
	mkdirSync(path.dirname(jsonOut), { recursive: true });

	const exitCode = await new Promise((resolve) => {
		const child = spawn("pnpm", ["exec", "playwright", "test", "--grep", "@deployed-safe"], {
			cwd: WEB_NEXT_ROOT,
			stdio: "inherit",
			env: {
				...process.env,
				VALIDATE_TARGET_URL: target.baseUrl,
				VALIDATE_ENV_NAME: target.envName,
				WEB_NEXT_VALIDATION_SESSION: env.WEB_NEXT_VALIDATION_SESSION,
				VALIDATE_E2E_JSON_OUTPUT: jsonOut,
			},
		});
		child.on("exit", (code) => resolve(code ?? 1));
		child.on("error", () => resolve(1));
	});

	if (!existsSync(jsonOut)) {
		return {
			id,
			status: "run",
			checks: [
				{
					id: "e2e:report_missing",
					status: "fail",
					detail: `playwright exited ${exitCode} without writing a JSON report at ${path.relative(WEB_NEXT_ROOT, jsonOut)}`,
				},
			],
		};
	}
	const report = JSON.parse(readFileSync(jsonOut, "utf8"));
	return { id, status: "run", checks: evaluateE2eResults(report) };
}

/** Runs a stage and stamps how long it took (the #819 report's timings). */
async function timed(run) {
	const started = Date.now();
	const stage = await run();
	return { ...stage, tookMs: Date.now() - started };
}

/** Every file under `dir`, repo-relative — the report's evidence links. */
function collectEvidenceFiles(dir) {
	if (!existsSync(dir)) return [];
	return readdirSync(dir, { recursive: true, withFileTypes: true })
		.filter((entry) => entry.isFile() && /\.(png|webm|zip)$/.test(entry.name))
		.map((entry) =>
			path.relative(WEB_NEXT_ROOT, path.join(entry.parentPath ?? entry.path, entry.name)),
		)
		.sort();
}

async function main() {
	const args = process.argv.slice(2);
	const target = resolveTarget(args, process.env);
	const skipRealTurn = args.includes("--skip-real-turn");
	let server;
	if (target.spawnLocal) {
		if (target.localMode) {
			const { env } = await localModeServerEnv("validate-local-mode");
			server = await startProductionServer(LOCAL_MODE_PORT, env);
			process.env.WEB_NEXT_LOCAL_TOKEN = env.WEB_NEXT_LOCAL_TOKEN;
		} else {
			const { env } = bypassServerEnv("validate-db");
			server = await startProductionServer(LOCAL_PORT, env);
		}
	}
	try {
		console.log(`validating ${target.envName}: ${target.baseUrl}\n`);
		const reach = await timed(() => reachabilityStage(target.baseUrl));
		const stages = [reach];
		// No point probing posture — or running the credentialed stages — on a
		// target that isn't serving (or is SSO-walled). Running the model sweep /
		// e2e against a wall would report app failures for what is a missing
		// bypass credential (codex finding); they inherit reachability's verdict
		// as their own skip reason instead.
		const reachable = reach.status === "run" && reach.checks.every((c) => c.status === "pass");
		const mode = detectAuthMode(reach.signIn?.body ?? "");
		if (reachable) {
			stages.push(await timed(() => postureStage(target.baseUrl, reach.signIn)));
			if (target.localMode) {
				stages.push(
					await timed(() =>
						localModeStage(target.baseUrl, process.env.WEB_NEXT_LOCAL_TOKEN),
					),
				);
			}
			stages.push(await timed(() => authenticatedStage(target.baseUrl, mode, process.env)));
			stages.push(await timed(() => modelSweepStage(target.baseUrl, process.env)));
			stages.push(await timed(() => e2eDeployedSafeStage(target, process.env)));
			// The real turn runs LAST: it is the only stage that spends real money
			// (one small coding turn) and boots a sandbox, so everything cheaper
			// gets its verdict in first. Local spawns skip it — the throwaway
			// bypass server has no deployed runtime posture worth probing, and
			// `pnpm validate` with no args must never surprise-spend.
			if (skipRealTurn) {
				stages.push({ id: REAL_TURN_STAGE_ID, status: "skip", reason: "skipped by flag (--skip-real-turn)" });
			} else if (target.spawnLocal) {
				stages.push({
					id: REAL_TURN_STAGE_ID,
					status: "skip",
					reason: "local spawn — probe a deployed target (or --url a server provisioned with runtime credentials)",
				});
			} else {
				const cookie = authedCookie(mode, target.baseUrl, process.env);
				if (!cookie) {
					const gate = gateStage({ WEB_NEXT_VALIDATION_SESSION: process.env.WEB_NEXT_VALIDATION_SESSION });
					stages.push({ id: REAL_TURN_STAGE_ID, status: "skip", reason: gate.reason });
				} else {
					stages.push(await timed(() => realTurnStage(target.baseUrl, cookie, process.env)));
				}
			}
		} else {
			const reason = reach.status === "skip" ? reach.reason : "target unreachable — see reachability stage";
			stages.push({ id: AUTHED_STAGE_ID, status: "skip", reason });
			stages.push({ id: MODEL_SWEEP_STAGE_ID, status: "skip", reason });
			stages.push({ id: E2E_STAGE_ID, status: "skip", reason });
			stages.push({ id: REAL_TURN_STAGE_ID, status: "skip", reason });
		}

		const summary = summarize(stages);
		console.log(summary.lines.join("\n"));

		const ranAt = new Date().toISOString();
		// The raw sign-in response rides on the reachability stage for the
		// posture probe; drop it from the persisted records.
		const persistedStages = stages.map((stage) => ({ ...stage, signIn: undefined }));

		const outDir = path.join(WEB_NEXT_ROOT, "output", "validate");
		mkdirSync(outDir, { recursive: true });
		const outFile = path.join(outDir, `${Date.now()}-${target.envName}.json`);
		writeFileSync(outFile, JSON.stringify({ target, ranAt, stages: persistedStages }, null, 2));

		// The #819 per-env report: same verdicts as the console summary, plus
		// timings and evidence paths, at a stable path the scheduled workflow
		// can pour into its job summary and upload as an artifact.
		const envDir = path.join(outDir, target.envName);
		mkdirSync(envDir, { recursive: true });
		const report = renderMarkdownReport({
			target,
			ranAt,
			stages: persistedStages,
			evidence: collectEvidenceFiles(envDir),
		});
		const reportFile = path.join(envDir, "report.md");
		writeFileSync(reportFile, report);
		console.log(`\nresults: ${path.relative(WEB_NEXT_ROOT, outFile)}`);
		console.log(`report:  ${path.relative(WEB_NEXT_ROOT, reportFile)}`);
		if (!summary.ok) {
			console.error(`\n${summary.failed} check(s) failed`);
			process.exitCode = 1;
		}
	} finally {
		await server?.stop();
	}
}

await main();
