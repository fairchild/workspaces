/*
 * Environment-targetable validation: `pnpm validate [--env local|prod | --url
 * <origin>]` runs the credential-free stages — reachability, then the
 * auth/security posture suite — plus the credentialed model-sweep (#816) and
 * deployed-safe e2e (#817) stages, against a local spawn or a real
 * deployment, and reports pass/fail/skip per check (JSON to output/validate/,
 * exit 1 on any failure). Stages needing credentials gate themselves and
 * report `skipped: missing <name>` rather than silently passing. #813/#815;
 * the authenticated and agentic stages (#814/#818) still extend this.
 */
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { MODEL_OPTIONS } from "../src/lib/agent-runtime/models.ts";
import {
	classifyModelSweepGate,
	detectAuthMode,
	detectSsoWall,
	evaluateE2eResults,
	evaluateModelChecks,
	evaluatePosture,
	gateStage,
	isRedirectToSignIn,
	LOCAL_PORT,
	redactSecrets,
	resolveTarget,
	summarize,
	validationSessionCookieName,
} from "./validate-core.mjs";
import { bypassServerEnv, startProductionServer, WEB_NEXT_ROOT } from "./harness.mjs";

const PROBE_TIMEOUT_MS = 15_000;

const MODEL_SWEEP_STAGE_ID = "model sweep (#816)";
const E2E_STAGE_ID = "e2e deployed-safe flows (#817)";

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

/** Placeholder for the authenticated stages: demonstrates explicit skip. */
function authenticatedStage(env) {
	const gate = gateStage({ WEB_NEXT_VALIDATION_SESSION: env.WEB_NEXT_VALIDATION_SESSION });
	return { id: "authenticated flows (#814)", status: "skip", reason: gate.runnable ? "not implemented" : gate.reason };
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

async function main() {
	const target = resolveTarget(process.argv.slice(2), process.env);
	let server;
	if (target.spawnLocal) {
		const { env } = bypassServerEnv("validate-db");
		server = await startProductionServer(LOCAL_PORT, env);
	}
	try {
		console.log(`validating ${target.envName}: ${target.baseUrl}\n`);
		const reach = await reachabilityStage(target.baseUrl);
		const stages = [reach];
		// No point probing posture — or running the credentialed stages — on a
		// target that isn't serving (or is SSO-walled). Running the model sweep /
		// e2e against a wall would report app failures for what is a missing
		// bypass credential (codex finding); they inherit reachability's verdict
		// as their own skip reason instead.
		const reachable = reach.status === "run" && reach.checks.every((c) => c.status === "pass");
		if (reachable) {
			stages.push(await postureStage(target.baseUrl, reach.signIn));
		}
		stages.push(authenticatedStage(process.env));
		if (reachable) {
			stages.push(await modelSweepStage(target.baseUrl, process.env));
			stages.push(await e2eDeployedSafeStage(target, process.env));
		} else {
			const reason = reach.status === "skip" ? reach.reason : "target unreachable — see reachability stage";
			stages.push({ id: MODEL_SWEEP_STAGE_ID, status: "skip", reason });
			stages.push({ id: E2E_STAGE_ID, status: "skip", reason });
		}

		const summary = summarize(stages);
		console.log(summary.lines.join("\n"));

		const outDir = path.join(WEB_NEXT_ROOT, "output", "validate");
		mkdirSync(outDir, { recursive: true });
		const outFile = path.join(outDir, `${Date.now()}-${target.envName}.json`);
		writeFileSync(
			outFile,
			JSON.stringify(
				{
					target,
					ranAt: new Date().toISOString(),
					// The raw sign-in response rides on the reachability stage for the
					// posture probe; drop it from the persisted record.
					stages: stages.map((stage) => ({ ...stage, signIn: undefined })),
				},
				null,
				2,
			),
		);
		console.log(`\nresults: ${path.relative(WEB_NEXT_ROOT, outFile)}`);
		if (!summary.ok) {
			console.error(`\n${summary.failed} check(s) failed`);
			process.exitCode = 1;
		}
	} finally {
		await server?.stop();
	}
}

await main();
