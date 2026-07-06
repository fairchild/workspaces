/*
 * Environment-targetable validation: `pnpm validate [--env local|prod | --url
 * <origin>]` runs the credential-free stages — reachability, then the
 * auth/security posture suite — against a local spawn or a real deployment,
 * and reports pass/fail/skip per check (JSON to output/validate/, exit 1 on
 * any failure). Stages needing credentials gate themselves and report
 * `skipped: missing <name>` rather than silently passing. #813/#815; the
 * authenticated, model, and agentic stages (#814/#816–#818) extend this.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import {
	detectAuthMode,
	evaluatePosture,
	gateStage,
	LOCAL_PORT,
	resolveTarget,
	summarize,
} from "./validate-core.mjs";
import { bypassServerEnv, startProductionServer, WEB_NEXT_ROOT } from "./harness.mjs";

const PROBE_TIMEOUT_MS = 15_000;

/** A fetch that never follows redirects and never throws on HTTP errors. */
async function probe(baseUrl, pathname, init = {}) {
	const method = init.method ?? "GET";
	try {
		const res = await fetch(`${baseUrl}${pathname}`, {
			...init,
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
		return { path: pathname, method, status: 0, body: String(error) };
	}
}

async function reachabilityStage(baseUrl) {
	const signIn = await probe(baseUrl, "/sign-in");
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
		// No point probing posture on a target that isn't serving.
		if (reach.checks.every((c) => c.status === "pass")) {
			stages.push(await postureStage(target.baseUrl, reach.signIn));
		}
		stages.push(authenticatedStage(process.env));

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
