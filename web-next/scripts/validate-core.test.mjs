import { describe, expect, test } from "vitest";
import {
	classifyModelSweepGate,
	DEFAULT_PROD_URL,
	detectAuthMode,
	detectSsoWall,
	evaluateE2eResults,
	evaluateModelChecks,
	evaluatePosture,
	gateStage,
	isRedirectToSignIn,
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
	expect(detectAuthMode("<button>Continue with GitHub</button>")).toBe("real");
});

describe("evaluatePosture", () => {
	const signIn = { status: 200, body: "Continue with GitHub" };
	const redirect = { status: 307, location: "/sign-in" };

	test("real mode: gated home, inert forged cookie, no-data APIs all pass", () => {
		const checks = evaluatePosture("real", {
			home: redirect,
			signIn,
			forgedCookieHome: redirect,
			api: [{ path: "/api/x", method: "GET", status: 401 }],
		});
		expect(checks.every((c) => c.status === "pass")).toBe(true);
	});

	test("real mode: a working forged cookie fails; a 200 API leak fails", () => {
		const checks = evaluatePosture("real", {
			home: redirect,
			signIn,
			forgedCookieHome: { status: 200 },
			api: [{ path: "/api/x", method: "GET", status: 200 }],
		});
		const byId = Object.fromEntries(checks.map((c) => [c.id, c.status]));
		expect(byId["forged_bypass_cookie_inert"]).toBe("fail");
		expect(byId["api_no_data:/api/x"]).toBe("fail");
	});

	test("bypass mode: the cookie signing in is the designed pass", () => {
		const checks = evaluatePosture("bypass", {
			home: redirect,
			signIn: { status: 200, body: "test bypass" },
			forgedCookieHome: { status: 200 },
			api: [{ path: "/api/x", method: "POST", status: 307 }],
		});
		expect(checks.every((c) => c.status === "pass")).toBe(true);
	});

	test("redirected API is a pass with the #828 wart named", () => {
		const [apiCheck] = evaluatePosture("real", {
			home: redirect,
			signIn,
			forgedCookieHome: redirect,
			api: [{ path: "/api/x", method: "GET", status: 307 }],
		}).filter((c) => c.id.startsWith("api_no_data"));
		expect(apiCheck.status).toBe("pass");
		expect(apiCheck.detail).toContain("#828");
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

	test("a clean 200 first probe runs the sweep", () => {
		expect(classifyModelSweepGate({ status: 200, body: { ok: true } })).toEqual({ skip: false });
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
