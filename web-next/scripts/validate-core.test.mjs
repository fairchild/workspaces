import { describe, expect, test } from "vitest";
import {
	authedCookie,
	classifyModelSweepGate,
	DEFAULT_PROD_URL,
	detectAuthMode,
	detectSsoWall,
	evaluateAuthedProbe,
	evaluateE2eResults,
	evaluateModelChecks,
	evaluatePosture,
	gateStage,
	isRedirectToSignIn,
	redactSecrets,
	renderMarkdownReport,
	resolveTarget,
	summarize,
	validationSessionCookieName,
} from "./validate-core.mjs";

describe("resolveTarget", () => {
	test("defaults to spawning local", () => {
		expect(resolveTarget([])).toMatchObject({ envName: "local", spawnLocal: true });
	});

	test("--env prod targets the known deployment, overridable by env", () => {
		expect(resolveTarget(["--env", "prod"]).baseUrl).toBe(DEFAULT_PROD_URL);
		expect(
			resolveTarget(["--env", "prod"], { WEB_NEXT_PROD_URL: "https://x.example/" }).baseUrl,
		).toBe("https://x.example");
	});

	test("--env local-mode spawns the owner-local target", () => {
		expect(resolveTarget(["--env", "local-mode"])).toMatchObject({
			envName: "local-mode",
			baseUrl: "http://localhost:3102",
			spawnLocal: true,
			localMode: true,
		});
	});

	test("--url wins and never spawns", () => {
		const t = resolveTarget(["--env", "preview", "--url", "https://pr-1.vercel.app/"]);
		expect(t).toMatchObject({
			envName: "preview",
			baseUrl: "https://pr-1.vercel.app",
			spawnLocal: false,
		});
	});

	test("rejects a non-origin --url and an env with no stable origin", () => {
		expect(() => resolveTarget(["--url", "pr-1.vercel.app"])).toThrow(/http/);
		expect(() => resolveTarget(["--env", "preview"])).toThrow(/--url/);
	});
});

test("detectAuthMode reads the door", () => {
	expect(detectAuthMode("<button>continue as fairchild (test bypass)</button>")).toBe("bypass");
	expect(detectAuthMode("<input placeholder='local sign-in token' />")).toBe("local");
	expect(detectAuthMode("<button>Continue with GitHub</button>")).toBe("real");
});

describe("evaluatePosture", () => {
	const signIn = { status: 200, body: "Continue with GitHub" };
	const redirect = { status: 307, location: "/sign-in" };

	const unauthJson = JSON.stringify({ error: "not signed in as the allowed user" });

	test("real mode: gated home, inert forged cookie, unauthenticated APIs answer 401 JSON", () => {
		const checks = evaluatePosture("real", {
			home: redirect,
			signIn,
			forgedCookieHome: redirect,
			api: [{ path: "/api/x", method: "GET", status: 401, body: unauthJson }],
		});
		expect(checks.every((c) => c.status === "pass")).toBe(true);
	});

	test("real mode: a working forged cookie fails; a 200 API leak fails", () => {
		const checks = evaluatePosture("real", {
			home: redirect,
			signIn,
			forgedCookieHome: { status: 200 },
			api: [{ path: "/api/x", method: "GET", status: 200, body: "" }],
		});
		const byId = Object.fromEntries(checks.map((c) => [c.id, c.status]));
		expect(byId["forged_bypass_cookie_inert"]).toBe("fail");
		expect(byId["api_unauthenticated_json:/api/x"]).toBe("fail");
	});

	test("bypass mode: the cookie signing in is the designed pass", () => {
		const checks = evaluatePosture("bypass", {
			home: redirect,
			signIn: { status: 200, body: "test bypass" },
			forgedCookieHome: { status: 200 },
			api: [{ path: "/api/x", method: "POST", status: 401, body: unauthJson }],
		});
		expect(checks.every((c) => c.status === "pass")).toBe(true);
	});

	test("local mode: no OAuth door, no bypass door, forged bypass cookie inert", () => {
		const checks = evaluatePosture("local", {
			home: redirect,
			signIn: { status: 200, body: "local sign-in token" },
			forgedCookieHome: redirect,
			api: [{ path: "/api/x", method: "POST", status: 401, body: unauthJson }],
		});
		expect(checks.every((c) => c.status === "pass")).toBe(true);
	});

	test("a redirect or a bodiless 401 both fail the #828 contract", () => {
		const [redirectCheck] = evaluatePosture("real", {
			home: redirect,
			signIn,
			forgedCookieHome: redirect,
			api: [{ path: "/api/x", method: "GET", status: 307, location: "/sign-in" }],
		}).filter((c) => c.id.startsWith("api_unauthenticated_json"));
		expect(redirectCheck.status).toBe("fail");

		const [bareCheck] = evaluatePosture("real", {
			home: redirect,
			signIn,
			forgedCookieHome: redirect,
			api: [{ path: "/api/x", method: "GET", status: 401, body: "" }],
		}).filter((c) => c.id.startsWith("api_unauthenticated_json"));
		expect(bareCheck.status).toBe("fail");
	});
});

test("gateStage reports what is missing, never silently passes", () => {
	expect(gateStage({ TOKEN: "x" })).toEqual({ runnable: true });
	expect(gateStage({ TOKEN: undefined, KEY: "" })).toEqual({
		runnable: false,
		reason: "missing TOKEN, KEY",
	});
});

test("summarize: skips are visible, any failed check flips the verdict", () => {
	const { ok, failed, lines } = summarize([
		{ id: "a", status: "run", checks: [{ id: "c1", status: "pass", detail: "d" }] },
		{ id: "b", status: "skip", reason: "missing TOKEN" },
		{ id: "c", status: "run", checks: [{ id: "c2", status: "fail", detail: "d" }] },
	]);
	expect(ok).toBe(false);
	expect(failed).toBe(1);
	expect(lines.join("\n")).toContain("skipped: missing TOKEN");
});

test("detectSsoWall spots Vercel deployment protection, not app redirects", () => {
	expect(
		detectSsoWall({ status: 302, location: "https://vercel.com/sso-api?url=x&nonce=y" }),
	).toBe(true);
	expect(detectSsoWall({ status: 307, location: "/sign-in" })).toBe(false);
	expect(detectSsoWall({ status: 200 })).toBe(false);
});

test("isRedirectToSignIn (shared by posture and the #817 session pre-check)", () => {
	expect(isRedirectToSignIn({ status: 307, location: "/sign-in" })).toBe(true);
	expect(isRedirectToSignIn({ status: 200, location: "/sign-in" })).toBe(false);
	expect(isRedirectToSignIn({ status: 307, location: "/" })).toBe(false);
});

test("validationSessionCookieName picks the __Secure- prefix over https, plain over http", () => {
	expect(validationSessionCookieName("https://preview.example.vercel.app")).toBe(
		"__Secure-better-auth.session_token",
	);
	expect(validationSessionCookieName("http://localhost:3101")).toBe(
		"better-auth.session_token",
	);
});

test("authedCookie can authenticate local-mode validation with the minted token", () => {
	expect(
		authedCookie("local", "http://localhost:3102", {
			WEB_NEXT_LOCAL_TOKEN: "local-secret",
		}),
	).toBe("web-next-local-session=local-secret");
	expect(authedCookie("local", "http://localhost:3102", {})).toBeNull();
});

describe("classifyModelSweepGate (#816)", () => {
	test("a 401/403 first probe means the validation session bounced — re-seed, not a failure", () => {
		expect(classifyModelSweepGate({ status: 401 })).toEqual({
			skip: true,
			reason: "validation session expired — re-seed",
		});
		expect(classifyModelSweepGate({ status: 403 })).toEqual({
			skip: true,
			reason: "validation session expired — re-seed",
		});
	});

	test("the route's exact missing-AI_GATEWAY_API_KEY message gates the whole stage as skipped", () => {
		expect(
			classifyModelSweepGate({
				status: 500,
				body: { ok: false, error: "AI_GATEWAY_API_KEY is not set in this deployment" },
			}),
		).toEqual({ skip: true, reason: "missing AI_GATEWAY_API_KEY in target deployment" });
	});

	test("an unrelated 500 is not swallowed as a credential gate", () => {
		expect(classifyModelSweepGate({ status: 500, body: { error: "boom" } })).toEqual({
			skip: false,
		});
	});

	test("a 500 merely mentioning the variable name is not a credential gate — exact message only (codex finding)", () => {
		expect(
			classifyModelSweepGate({
				status: 500,
				body: { error: "failed while reading AI_GATEWAY_API_KEY from config" },
			}),
		).toEqual({ skip: false });
	});

	test("a transient network blip (status 0) is a fail path, never a credential skip (codex-verified)", () => {
		expect(classifyModelSweepGate({ status: 0, body: undefined })).toEqual({ skip: false });
	});

	test("a clean 200 first probe runs the sweep", () => {
		expect(classifyModelSweepGate({ status: 200, body: { ok: true } })).toEqual({ skip: false });
	});
});

describe("redactSecrets (codex finding: fetch header errors echo credential values)", () => {
	test("replaces every occurrence of each secret", () => {
		expect(
			redactSecrets("TypeError: invalid header value: 'sekret\\n' (from sekret)", ["sekret"]),
		).toBe("TypeError: invalid header value: '[redacted]\\n' (from [redacted])");
	});

	test("unset/empty secrets are inert and non-matching text passes through", () => {
		expect(redactSecrets("plain error", [undefined, ""])).toBe("plain error");
	});
});

describe("evaluateModelChecks (#816)", () => {
	test("a routed, replying model passes with the gateway id and latency in the detail", () => {
		const checks = evaluateModelChecks([
			{
				id: "claude-haiku-4-5",
				status: 200,
				body: { ok: true, gatewayModel: "anthropic/claude-haiku-4.5", reply: "gateway live", latencyMs: 812 },
			},
		]);
		expect(checks).toEqual([
			{
				id: "model:claude-haiku-4-5",
				status: "pass",
				detail: 'claude-haiku-4-5 → routed via anthropic/claude-haiku-4.5 in 812ms: "gateway live"',
			},
		]);
	});

	test("a non-200 or empty-reply model fails, one check per model, independent of the others", () => {
		const checks = evaluateModelChecks([
			{ id: "claude-fable-5", status: 200, body: { ok: true, reply: "gateway live" } },
			{ id: "claude-opus-4-8", status: 502, body: { ok: false, status: 429, upstream: { error: "rate limited" } } },
			{ id: "claude-sonnet-5", status: 200, body: { ok: true, reply: "" } },
		]);
		const byId = Object.fromEntries(checks.map((c) => [c.id, c.status]));
		expect(byId["model:claude-fable-5"]).toBe("pass");
		expect(byId["model:claude-opus-4-8"]).toBe("fail");
		expect(byId["model:claude-sonnet-5"]).toBe("fail");
	});

	test("an unreachable probe (no body at all) is a failed check, not a crash", () => {
		const checks = evaluateModelChecks([
			{ id: "claude-fable-5", status: 0, body: undefined },
		]);
		expect(checks).toEqual([
			{
				id: "model:claude-fable-5",
				status: "fail",
				detail: "claude-fable-5 → HTTP 0 null",
			},
		]);
	});
});

describe("evaluateE2eResults (#817)", () => {
	function report(specs, extraSuites = []) {
		return { suites: [{ title: "sample.spec.ts", specs }, ...extraSuites] };
	}

	test("one check per spec, pass/fail from Playwright's own ok verdict", () => {
		const checks = evaluateE2eResults(
			report([
				{ title: "theme toggles @deployed-safe", ok: true, tests: [{ status: "expected" }] },
				{ title: "compose autofocuses @deployed-safe", ok: false, tests: [{ status: "unexpected" }] },
			]),
		);
		expect(checks).toEqual([
			{ id: "e2e:theme toggles @deployed-safe", status: "pass", detail: "theme toggles @deployed-safe → expected" },
			{
				id: "e2e:compose autofocuses @deployed-safe",
				status: "fail",
				detail: "compose autofocuses @deployed-safe → unexpected",
			},
		]);
	});

	test("walks nested suites (describe blocks) too", () => {
		const nested = evaluateE2eResults({
			suites: [
				{
					title: "outer",
					specs: [],
					suites: [{ title: "inner", specs: [{ title: "a @deployed-safe", ok: true, tests: [{ status: "expected" }] }] }],
				},
			],
		});
		expect(nested).toHaveLength(1);
		expect(nested[0].id).toBe("e2e:a @deployed-safe");
	});

	test("zero matched specs is a failing check, not a silent 0/0 pass", () => {
		const checks = evaluateE2eResults({ suites: [] });
		expect(checks).toEqual([
			{
				id: "e2e:no_specs_matched",
				status: "fail",
				detail: "no deployed-safe specs matched — check the @deployed-safe grep tag",
			},
		]);
	});
});

describe("authedCookie", () => {
	test("bypass mode uses the test cookie with no credential gate", () => {
		expect(authedCookie("bypass", "http://localhost:3101", {})).toBe(
			"test-auth-login=fairchild",
		);
	});

	test("real mode replays the validation session under the https cookie name", () => {
		expect(
			authedCookie("real", "https://x.vercel.app", { WEB_NEXT_VALIDATION_SESSION: "tok" }),
		).toBe("__Secure-better-auth.session_token=tok");
	});

	test("real mode without the credential yields null (stage gates itself)", () => {
		expect(authedCookie("real", "https://x.vercel.app", {})).toBeNull();
	});
});

describe("evaluateAuthedProbe (#814)", () => {
	test("200 with the client's shape passes both checks", () => {
		const checks = evaluateAuthedProbe({ status: 200, body: { repos: [], degraded: false } });
		expect(checks.map((c) => c.status)).toEqual(["pass", "pass"]);
	});

	test("200 with a foreign shape fails the shape check", () => {
		const checks = evaluateAuthedProbe({ status: 200, body: { html: "<!doctype html>" } });
		expect(checks.map((c) => c.status)).toEqual(["pass", "fail"]);
	});

	test("a non-200 fails both", () => {
		const checks = evaluateAuthedProbe({ status: 500, body: undefined });
		expect(checks.every((c) => c.status === "fail")).toBe(true);
	});
});

describe("renderMarkdownReport (#819)", () => {
	const run = {
		target: { envName: "prod", baseUrl: "https://x.vercel.app" },
		ranAt: "2026-07-07T00:00:00Z",
		stages: [
			{
				id: "reachability",
				status: "run",
				tookMs: 400,
				checks: [{ id: "signin_reachable", status: "pass", detail: "→ 200" }],
			},
			{ id: "authenticated flows (#814)", status: "skip", reason: "missing WEB_NEXT_VALIDATION_SESSION" },
			{
				id: "real agentic turn (#818)",
				status: "run",
				tookMs: 61_000,
				checks: [
					{ id: "session_created", status: "pass", detail: "probe session p1" },
					{ id: "no_leaked_sandbox", status: "fail", detail: "LEAK: could not stop" },
				],
			},
		],
		evidence: ["output/validate/prod/test-results/home.png"],
	};

	test("renders the stage table with verdicts, counts, and timings", () => {
		const md = renderMarkdownReport(run);
		expect(md).toContain("# web-next validation — prod");
		expect(md).toContain("| reachability | ✅ pass | 1/1 | 0.4s |");
		expect(md).toContain("| authenticated flows (#814) | ⏭️ skipped | — | — |");
		expect(md).toContain("| real agentic turn (#818) | ❌ FAIL | 1/2 | 61.0s |");
	});

	test("skips carry their reasons and failures their detail", () => {
		const md = renderMarkdownReport(run);
		expect(md).toContain("- **authenticated flows (#814)** — missing WEB_NEXT_VALIDATION_SESSION");
		expect(md).toContain("- **real agentic turn (#818)** / `no_leaked_sandbox`: LEAK: could not stop");
	});

	test("evidence paths are listed", () => {
		expect(renderMarkdownReport(run)).toContain("output/validate/prod/test-results/home.png");
	});

	test("an all-green run has no failing-checks section", () => {
		const md = renderMarkdownReport({ ...run, stages: [run.stages[0]], evidence: [] });
		expect(md).not.toContain("## Failing checks");
		expect(md).not.toContain("## Skipped");
		expect(md).not.toContain("## Evidence");
	});
});
