/*
 * Pure logic for the environment-targetable validation runner (validate.mjs):
 * target resolution (--env/--url), auth-mode detection, the posture checks
 * evaluated over probe results, the #816 model-sweep and #817 e2e result
 * interpreters, and the summary/exit semantics. No I/O here — everything is
 * unit-testable (scripts/validate-core.test.mjs).
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

/**
 * Vercel deployment protection intercepts before the app: a 3xx to
 * vercel.com/sso-api. That is a credential gate (the automation-bypass
 * secret, #814), not an app failure — callers report it as a skip.
 */
export function detectSsoWall(probeResult) {
	return (
		probeResult.status >= 300 &&
		probeResult.status < 400 &&
		/vercel\.com\/sso-api/.test(probeResult.location ?? "")
	);
}

function check(id, pass, detail) {
	return { id, status: pass ? "pass" : "fail", detail };
}

/**
 * A redirect to /sign-in: the middleware's verdict for no-or-stale session,
 * whichever auth mode is active. Exported for the #817 e2e stage's own
 * pre-check (a deployed-target page load with a bounced validation session
 * redirects the same way, before any browser ever opens).
 */
export const isRedirectToSignIn = (probe) =>
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

/**
 * The Better Auth session-token cookie name is protocol-dependent (Better
 * Auth applies the `__Secure-` prefix over https — see
 * `src/lib/auth/session-cookie.ts`'s SESSION_TOKEN_COOKIES). A deployed
 * target is always https; `http://localhost` never is, so this only ever
 * picks the plain name in that case (unused there in practice — local runs
 * use the AUTH_BYPASS cookie instead).
 */
export function validationSessionCookieName(baseUrl) {
	return baseUrl.startsWith("https://")
		? "__Secure-better-auth.session_token"
		: "better-auth.session_token";
}

/**
 * Interprets the first probe of the #816 model sweep to decide whether the
 * stage is even runnable in this target — distinct from any individual
 * model's pass/fail. Two gates, both reported as skips (never a fail):
 * a bounced validation session (the decision doc's "expired — re-seed"
 * state) and a target deployment with no gateway credential at all.
 */
export function classifyModelSweepGate(firstProbe) {
	if (firstProbe.status === 401 || firstProbe.status === 403) {
		return { skip: true, reason: "validation session expired — re-seed" };
	}
	if (firstProbe.status === 500) {
		const error = firstProbe.body && typeof firstProbe.body === "object" ? firstProbe.body.error : undefined;
		if (typeof error === "string" && /AI_GATEWAY_API_KEY/.test(error)) {
			return { skip: true, reason: "missing AI_GATEWAY_API_KEY in target deployment" };
		}
	}
	return { skip: false };
}

/**
 * Turns raw `/api/diag/gateway?model=<id>` probe results into per-model pass/
 * fail checks. `results`: `[{ id, status, body }]`, `body` already JSON-
 * parsed (or `undefined` if the probe returned unparseable/empty text).
 */
export function evaluateModelChecks(results) {
	return results.map(({ id, status, body }) => {
		const ok = status === 200 && !!body && body.ok === true && typeof body.reply === "string" && body.reply.length > 0;
		return {
			id: `model:${id}`,
			status: ok ? "pass" : "fail",
			detail: ok
				? `${id} → routed via ${body.gatewayModel ?? "?"} in ${body.latencyMs ?? "?"}ms: ${JSON.stringify(body.reply)}`
				: `${id} → HTTP ${status} ${JSON.stringify(body).slice(0, 200)}`,
		};
	});
}

/**
 * Flattens a Playwright JSON-reporter report (any nesting of `suites`) into
 * one entry per spec — a spec's `ok` is Playwright's own verdict across its
 * (possibly retried) test runs, so it already accounts for flake/retries.
 */
function flattenSpecs(suites, out = []) {
	for (const suite of suites) {
		for (const spec of suite.specs ?? []) {
			out.push(spec);
		}
		if (suite.suites?.length) flattenSpecs(suite.suites, out);
	}
	return out;
}

/**
 * Interprets a Playwright JSON-reporter report (the #817 deployed-safe e2e
 * run) into validate.mjs checks, one per spec. A report with zero matched
 * specs (an empty `--grep` match — e.g. the deployed-safe tag was removed or
 * misspelled) is reported as its own failing check rather than silently
 * "0/0 passed", since that would otherwise read as a clean run.
 */
export function evaluateE2eResults(report) {
	const specs = flattenSpecs(report.suites ?? []);
	if (specs.length === 0) {
		return [{ id: "e2e:no_specs_matched", status: "fail", detail: "no deployed-safe specs matched — check the @deployed-safe grep tag" }];
	}
	return specs.map((spec) => {
		const statuses = spec.tests.map((t) => t.status);
		return {
			id: `e2e:${spec.title}`,
			status: spec.ok ? "pass" : "fail",
			detail: `${spec.title} → ${statuses.join(", ")}`,
		};
	});
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
