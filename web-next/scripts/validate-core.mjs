/*
 * Pure logic for the environment-targetable validation runner (validate.mjs):
 * target resolution (--env/--url), auth-mode detection, the posture checks
 * evaluated over probe results, and the summary/exit semantics. No I/O here —
 * everything is unit-testable (scripts/validate-core.test.mjs).
 */

/** The deployed production origin; override with WEB_NEXT_PROD_URL. */
export const DEFAULT_PROD_URL = "https://web-next-ivory-six.vercel.app";

export const LOCAL_PORT = 3101;

/**
 * Resolves what a run targets. `--url <origin>` wins; `--env local` spawns a
 * production build in auth-bypass mode; `--env prod` targets the known
 * deployment. `preview`/`staging` have no stable origin, so they require
 * an explicit --url.
 */
export function resolveTarget(args, env = {}) {
	const get = (flag) => {
		const at = args.indexOf(flag);
		return at >= 0 ? args[at + 1] : undefined;
	};
	const url = get("--url");
	if (url) {
		if (!/^https?:\/\//.test(url)) {
			throw new Error(`--url must be an http(s) origin, got: ${url}`);
		}
		return { envName: get("--env") ?? "url", baseUrl: url.replace(/\/$/, ""), spawnLocal: false };
	}
	const envName = get("--env") ?? "local";
	if (envName === "local") {
		return { envName, baseUrl: `http://localhost:${LOCAL_PORT}`, spawnLocal: true };
	}
	if (envName === "prod") {
		return {
			envName,
			baseUrl: (env.WEB_NEXT_PROD_URL ?? DEFAULT_PROD_URL).replace(/\/$/, ""),
			spawnLocal: false,
		};
	}
	throw new Error(
		`--env ${envName} has no stable origin; pass --url <origin> (known envs: local, prod)`,
	);
}

/**
 * Which door is this deployment showing? The test-bypass button only renders
 * when AUTH_BYPASS is active (and is hard-disabled by a real OAuth app), so
 * its presence distinguishes the modes from the outside.
 */
export function detectAuthMode(signInHtml) {
	return /test bypass/i.test(signInHtml) ? "bypass" : "real";
}

function check(id, pass, detail) {
	return { id, status: pass ? "pass" : "fail", detail };
}

const isRedirectToSignIn = (probe) =>
	probe.status >= 300 && probe.status < 400 && /\/sign-in/.test(probe.location ?? "");

/**
 * Evaluates the posture checks over the probe results gathered by the runner.
 * `probes`: { home, signIn, forgedCookieHome, api: [{path, method, status, body}] }.
 * Every check is mode-aware: in bypass mode the forged cookie *working* is the
 * designed behavior; in real mode it must be inert.
 */
export function evaluatePosture(mode, probes) {
	const checks = [];

	checks.push(
		check(
			"home_gated",
			isRedirectToSignIn(probes.home),
			`GET / (unauthenticated) → ${probes.home.status} ${probes.home.location ?? ""}`,
		),
	);
	checks.push(
		check("signin_serves", probes.signIn.status === 200, `GET /sign-in → ${probes.signIn.status}`),
	);
	if (mode === "real") {
		checks.push(
			check(
				"no_bypass_button",
				!/test bypass/i.test(probes.signIn.body ?? ""),
				"real-auth door must not offer the test bypass",
			),
		);
		checks.push(
			check(
				"forged_bypass_cookie_inert",
				isRedirectToSignIn(probes.forgedCookieHome),
				`GET / with forged test-auth-login → ${probes.forgedCookieHome.status}`,
			),
		);
	} else {
		checks.push(
			check(
				"bypass_cookie_signs_in",
				probes.forgedCookieHome.status === 200,
				`GET / with test-auth-login cookie → ${probes.forgedCookieHome.status} (bypass mode)`,
			),
		);
	}
	for (const api of probes.api) {
		// The floor is "no data": never 2xx for an unauthenticated API call.
		// 401/403 is the route-level answer; 307 is the middleware wart (#828).
		checks.push(
			check(
				`api_no_data:${api.path}`,
				api.status >= 300,
				`${api.method} ${api.path} → ${api.status}${api.status >= 300 && api.status < 400 ? " (redirect, not 401 JSON — #828)" : ""}`,
			),
		);
	}
	return checks;
}

/**
 * Stage gating: a stage with unmet requirements is reported skipped with the
 * missing names, never silently passed. `requirements` maps name → truthy.
 */
export function gateStage(requirements) {
	const missing = Object.entries(requirements)
		.filter(([, present]) => !present)
		.map(([name]) => name);
	return missing.length === 0
		? { runnable: true }
		: { runnable: false, reason: `missing ${missing.join(", ")}` };
}

/** Collapses stage results into the exit verdict and the human summary lines. */
export function summarize(stages) {
	const lines = [];
	let failed = 0;
	for (const stage of stages) {
		if (stage.status === "skip") {
			lines.push(`○ ${stage.id} — skipped: ${stage.reason}`);
			continue;
		}
		const bad = stage.checks.filter((c) => c.status === "fail");
		failed += bad.length;
		lines.push(`${bad.length === 0 ? "✓" : "✗"} ${stage.id} — ${stage.checks.length - bad.length}/${stage.checks.length} checks`);
		for (const c of stage.checks) {
			lines.push(`   ${c.status === "pass" ? "✓" : "✗"} ${c.id}: ${c.detail}`);
		}
	}
	return { ok: failed === 0, failed, lines };
}
