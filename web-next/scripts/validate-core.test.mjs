import { describe, expect, test } from "vitest";
import {
	DEFAULT_PROD_URL,
	detectAuthMode,
	evaluatePosture,
	gateStage,
	resolveTarget,
	summarize,
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
