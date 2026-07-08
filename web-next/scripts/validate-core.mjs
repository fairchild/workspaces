/*
 * Pure logic for the environment-targetable validation runner (validate.mjs):
 * target resolution (--env/--url), auth-mode detection, the posture checks
 * evaluated over probe results, the #816 model-sweep and #817 e2e result
 * interpreters, and the summary/exit semantics. No I/O here — everything is
 * unit-testable (scripts/validate-core.test.mjs).
 */

/** The deployed production origin; override with WEB_NEXT_PROD_URL. */
export const DEFAULT_PROD_URL = "https://folio.cloudcompute.com";

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
 * The #828 contract: an unauthenticated API call answers 401 with the same
 * `{ error }` JSON shape every route's own getAuthState gate returns —
 * never an HTML redirect, never a bare 401 with no body.
 */
function isUnauthenticatedApiJson(probe) {
	if (probe.status !== 401) return false;
	try {
		const parsed = JSON.parse(probe.body ?? "");
		return typeof parsed === "object" && parsed !== null && typeof parsed.error === "string";
	} catch {
		return false;
	}
}

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
		// The contract (#828): an unauthenticated API call gets the route-level
		// 401 JSON answer straight from the edge — never an HTML redirect and
		// never a 2xx leak.
		checks.push(
			check(
				`api_unauthenticated_json:${api.path}`,
				isUnauthenticatedApiJson(api),
				`${api.method} ${api.path} → ${api.status}${api.status === 401 ? "" : " (expected 401 JSON)"}`,
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
 * The cookie an authenticated stage sends, chosen by the target's observed
 * auth mode: a bypass-mode target (local spawn / e2e server) accepts the test
 * cookie with no credential at all, while a real-auth target needs the
 * pre-minted validation session (#814). `null` means the stage can't
 * authenticate and should gate itself with `gateStage`.
 */
export function authedCookie(mode, baseUrl, env) {
	if (mode === "bypass") return "test-auth-login=fairchild";
	if (!env.WEB_NEXT_VALIDATION_SESSION) return null;
	return `${validationSessionCookieName(baseUrl)}=${env.WEB_NEXT_VALIDATION_SESSION}`;
}

/**
 * #814's authenticated-flows check: an authenticated GET of an auth-gated,
 * data-reading API (`/api/repos`) must answer 200 with the shape the client
 * is built against. This proves the validation identity clears the full auth
 * stack (middleware freshness + allowlist verdict) end to end.
 */
export function evaluateAuthedProbe(probe) {
	const ok200 = probe.status === 200;
	const body = probe.body;
	const shapeOk =
		!!body && Array.isArray(body.repos) && typeof body.degraded === "boolean";
	return [
		{
			id: "authed_api_200",
			status: ok200 ? "pass" : "fail",
			detail: `GET /api/repos (authenticated) → ${probe.status}`,
		},
		{
			id: "authed_api_shape",
			status: ok200 && shapeOk ? "pass" : "fail",
			detail: shapeOk
				? `repos: ${body.repos.length}, degraded: ${body.degraded}`
				: "response is not { repos: [...], degraded: boolean }",
		},
	];
}

/**
 * Replaces every occurrence of the given secret values in a string with a
 * placeholder. Probe/report text can otherwise carry a secret verbatim: a
 * malformed credential (say, a trailing newline from a sloppy copy-paste)
 * makes Node's fetch throw an invalid-header error whose message *echoes the
 * header value* — and that error string flows into check details and the
 * persisted JSON report (codex review finding).
 */
export function redactSecrets(text, secrets) {
	let out = text;
	for (const secret of secrets) {
		if (secret) out = out.split(secret).join("[redacted]");
	}
	return out;
}

/** The exact error the diag route reports when the target has no gateway key. */
export const MISSING_GATEWAY_KEY_ERROR = "AI_GATEWAY_API_KEY is not set in this deployment";

/**
 * Interprets the first probe of the #816 model sweep to decide whether the
 * stage is even runnable in this target — distinct from any individual
 * model's pass/fail. Two gates, both reported as skips (never a fail):
 * a bounced validation session (the decision doc's "expired — re-seed"
 * state) and a target deployment with no gateway credential at all (matched
 * against the route's exact message, so an unrelated 500 that merely
 * mentions the variable name can't masquerade as a credential gate).
 */
export function classifyModelSweepGate(firstProbe) {
	if (firstProbe.status === 401 || firstProbe.status === 403) {
		return { skip: true, reason: "validation session expired — re-seed" };
	}
	if (firstProbe.status === 500) {
		const error = firstProbe.body && typeof firstProbe.body === "object" ? firstProbe.body.error : undefined;
		if (error === MISSING_GATEWAY_KEY_ERROR) {
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
				: `${id} → HTTP ${status} ${JSON.stringify(body ?? null).slice(0, 200)}`,
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

const STATUS_LABEL = {
	pass: "✅ pass",
	fail: "❌ FAIL",
	skip: "⏭️ skipped",
};

function stageVerdict(stage) {
	if (stage.status === "skip") return "skip";
	return stage.checks.some((c) => c.status === "fail") ? "fail" : "pass";
}

const formatSeconds = (ms) =>
	typeof ms === "number" ? `${(ms / 1000).toFixed(1)}s` : "—";

/**
 * The #819 human report: one Markdown document per run — stage table with
 * timings, failing-check detail, skip reasons, and evidence paths — written
 * alongside the JSON record and suitable verbatim as a PR/handoff note or a
 * CI job summary. Pure renderer: callers gather the evidence file list.
 */
export function renderMarkdownReport(run) {
	const { target, ranAt, stages, evidence = [] } = run;
	const lines = [
		`# web-next validation — ${target.envName}`,
		"",
		`Target: ${target.baseUrl} · ran ${ranAt} · total ${formatSeconds(
			stages.reduce((sum, s) => sum + (s.tookMs ?? 0), 0),
		)}`,
		"",
		"| Stage | Result | Checks | Took |",
		"|---|---|---|---|",
	];
	for (const stage of stages) {
		const verdict = stageVerdict(stage);
		const checks =
			stage.status === "skip"
				? "—"
				: `${stage.checks.filter((c) => c.status === "pass").length}/${stage.checks.length}`;
		lines.push(
			`| ${stage.id} | ${STATUS_LABEL[verdict]} | ${checks} | ${formatSeconds(stage.tookMs)} |`,
		);
	}

	const skipped = stages.filter((s) => s.status === "skip");
	if (skipped.length > 0) {
		lines.push("", "## Skipped");
		for (const stage of skipped) {
			lines.push(`- **${stage.id}** — ${stage.reason}`);
		}
	}

	const failing = stages.flatMap((stage) =>
		(stage.checks ?? [])
			.filter((c) => c.status === "fail")
			.map((c) => ({ stage: stage.id, ...c })),
	);
	if (failing.length > 0) {
		lines.push("", "## Failing checks");
		for (const f of failing) {
			lines.push(`- **${f.stage}** / \`${f.id}\`: ${f.detail}`);
		}
	}

	if (evidence.length > 0) {
		lines.push("", "## Evidence");
		for (const file of evidence) {
			lines.push(`- \`${file}\``);
		}
	}

	lines.push("");
	return lines.join("\n");
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
