import { describe, expect, test } from "vitest";
import {
	buildProbePrompt,
	buildProbeTitle,
	classifyCreateGate,
	classifyPreflightGate,
	classifyTeardown,
	checkDefaultModel,
	evaluateRealTurnEvents,
	PROBE_FILE,
	runRealTurnProbe,
} from "./real-turn-core.mjs";

const NONCE = "abc123deadbeef00";

const ev = (role, kind, content = "", metadata = undefined) => ({
	seq: 0,
	role,
	kind,
	content,
	metadata,
});

/** A complete, healthy turn as it lands in the durable log. */
function happyEvents() {
	return [
		ev("user", "text", buildProbePrompt(NONCE)),
		ev("assistant", "status", "Minting GitHub credential"),
		ev("assistant", "status", "Booting Claude Code in sandbox"),
		ev("assistant", "text", "Creating the probe file."),
		ev("assistant", "tool_use", "Write", { input: { file_path: PROBE_FILE } }),
		ev("assistant", "tool_result", `Wrote ${PROBE_FILE}`),
		ev("assistant", "tool_use", "Bash", { input: { command: `cat ${PROBE_FILE}` } }),
		ev("assistant", "tool_result", `real-turn probe ${NONCE}`),
		ev("assistant", "done", "", { durationMs: 42000 }),
	];
}

describe("probe prompt/title", () => {
	test("prompt embeds the nonce and forbids PRs", () => {
		const prompt = buildProbePrompt(NONCE);
		expect(prompt).toContain(NONCE);
		expect(prompt).toContain(PROBE_FILE);
		expect(prompt).toMatch(/do not commit, push, or open a pull request/i);
	});

	test("title marks the session as a validation probe (the no-litter rule)", () => {
		expect(buildProbeTitle("2026-07-07T00:00:00Z")).toBe(
			"validation: real-turn probe 2026-07-07T00:00:00Z",
		);
	});
});

describe("classifyPreflightGate", () => {
	test("auth bounce and missing route are skips", () => {
		expect(classifyPreflightGate({ status: 401 })).toMatchObject({ skip: true });
		expect(classifyPreflightGate({ status: 404 }).reason).toMatch(/predates/);
	});

	test("a 503 rooted in the env-presence check is a not-provisioned skip", () => {
		const gate = classifyPreflightGate({
			status: 503,
			body: {
				checks: [
					{ name: "env", ok: false, error: "missing AI_GATEWAY_API_KEY" },
					{ name: "model_inference", ok: false, error: "no key" },
				],
			},
		});
		expect(gate).toMatchObject({ skip: true });
		expect(gate.reason).toMatch(/AI_GATEWAY_API_KEY/);
	});

	test("a 503 with env present is a real finding, not a skip", () => {
		const gate = classifyPreflightGate({
			status: 503,
			body: {
				checks: [
					{ name: "env", ok: true },
					{ name: "model_inference", ok: false, error: "gateway 500" },
				],
			},
		});
		expect(gate).toMatchObject({ fail: true });
		expect(gate.detail).toMatch(/model_inference/);
	});

	test("200 runs the stage", () => {
		expect(classifyPreflightGate({ status: 200 })).toEqual({ ok: true });
	});
});

describe("classifyCreateGate", () => {
	test("routes not deployed on the target is a skip, not a failure", () => {
		expect(classifyCreateGate({ status: 404 }).skip).toBe(true);
		expect(classifyCreateGate({ status: 405 }).skip).toBe(true);
	});

	test("auth bounce is the shared expired-session skip", () => {
		expect(classifyCreateGate({ status: 401 }).reason).toMatch(/re-seed/);
	});

	test("anything else proceeds to hard assertions", () => {
		expect(classifyCreateGate({ status: 201 })).toEqual({ ok: true });
		expect(classifyCreateGate({ status: 500 })).toEqual({ ok: true });
	});
});

describe("evaluateRealTurnEvents", () => {
	test("a healthy turn passes all five assertions", () => {
		const checks = evaluateRealTurnEvents(happyEvents(), NONCE);
		expect(checks.map((c) => [c.id, c.status])).toEqual([
			["sandbox_created", "pass"],
			["streamed_output", "pass"],
			["coding_change_landed", "pass"],
			["no_turn_errors", "pass"],
			["turn_done", "pass"],
		]);
	});

	test("the nonce in a synthesized workspace diff also proves the change", () => {
		const events = happyEvents().filter((e) => !(e.content ?? "").includes(NONCE));
		events.splice(events.length - 1, 0, {
			...ev("assistant", "tool_result", "", {
				diff: { file: PROBE_FILE, lines: [{ kind: "add", text: `+real-turn probe ${NONCE}` }] },
			}),
		});
		const change = evaluateRealTurnEvents(events, NONCE).find(
			(c) => c.id === "coding_change_landed",
		);
		expect(change.status).toBe("pass");
		expect(change.detail).toMatch(/diff/);
	});

	test("narration without tool output containing the nonce fails the change assertion", () => {
		const events = happyEvents().map((e) =>
			e.kind === "tool_result" ? { ...e, content: "done!" } : e,
		);
		const change = evaluateRealTurnEvents(events, NONCE).find(
			(c) => c.id === "coding_change_landed",
		);
		expect(change.status).toBe("fail");
	});

	test("a user event containing the nonce (the prompt itself) is never evidence", () => {
		const events = [ev("user", "text", `please write real-turn probe ${NONCE}`)];
		const change = evaluateRealTurnEvents(events, NONCE).find(
			(c) => c.id === "coding_change_landed",
		);
		expect(change.status).toBe("fail");
	});

	test("an errored turn fails no_turn_errors and an aborted done fails turn_done", () => {
		const events = [
			ev("assistant", "status", "Booting Claude Code in sandbox"),
			ev("assistant", "error", "sandbox exploded"),
			ev("assistant", "done", "", { aborted: true }),
		];
		const byId = Object.fromEntries(
			evaluateRealTurnEvents(events, NONCE).map((c) => [c.id, c]),
		);
		expect(byId.no_turn_errors.status).toBe("fail");
		expect(byId.no_turn_errors.detail).toMatch(/sandbox exploded/);
		expect(byId.turn_done.status).toBe("fail");
	});

	test("a missing done reports the deadline and the sandbox lifetime cap", () => {
		const done = evaluateRealTurnEvents([], NONCE, { deadlineMs: 480_000 }).find(
			(c) => c.id === "turn_done",
		);
		expect(done.status).toBe("fail");
		expect(done.detail).toMatch(/480s/);
		expect(done.detail).toMatch(/lifetime cap/);
	});
});

describe("checkDefaultModel", () => {
	test("passes only when the created session carries the default", () => {
		expect(checkDefaultModel({ model: "m1" }, "m1").status).toBe("pass");
		expect(checkDefaultModel({ model: "m2" }, "m1").status).toBe("fail");
		expect(checkDefaultModel(undefined, "m1").status).toBe("fail");
	});
});

describe("classifyTeardown (leak semantics)", () => {
	test("a parked session must yield a stopped or expired sandbox", () => {
		expect(
			classifyTeardown(true, { status: 200, body: { deleted: true, sandbox: "stopped" } }).status,
		).toBe("pass");
		expect(
			classifyTeardown(true, { status: 200, body: { deleted: true, sandbox: "expired" } }).status,
		).toBe("pass");
	});

	test("an unparked session yields none", () => {
		expect(
			classifyTeardown(false, { status: 200, body: { deleted: true, sandbox: "none" } }).status,
		).toBe("pass");
	});

	test("a parked session whose sandbox reports none is suspicious — fail", () => {
		expect(
			classifyTeardown(true, { status: 200, body: { deleted: true, sandbox: "none" } }).status,
		).toBe("fail");
	});

	test("stop-failed is the leak — a live sandbox we could not stop", () => {
		const verdict = classifyTeardown(true, {
			status: 502,
			body: { sandbox: "stop-failed", error: "api timeout" },
		});
		expect(verdict.status).toBe("fail");
		expect(verdict.detail).toMatch(/LEAK/);
	});

	test("an undeleted probe session is litter and fails too", () => {
		expect(classifyTeardown(false, { status: 500, body: {} }).status).toBe("fail");
	});
});

describe("runRealTurnProbe", () => {
	const options = (over = {}) => ({
		nonce: NONCE,
		defaultModel: "model-default",
		nowIso: "2026-07-07T00:00:00Z",
		deadlineMs: 10,
		pollMs: 1,
		sleep: () => Promise.resolve(),
		...over,
	});

	function happyClient(log = []) {
		return {
			createSession: async (body) => {
				log.push(["create", body]);
				return { status: 201, body: { id: "probe-1", model: "model-default" } };
			},
			sendChat: async (id, text) => {
				log.push(["chat", id, text]);
				return { status: 200 };
			},
			getSession: async (id) => {
				log.push(["get", id]);
				return {
					status: 200,
					body: { session: { parked: true }, events: happyEvents() },
				};
			},
			deleteSession: async (id) => {
				log.push(["delete", id]);
				return { status: 200, body: { deleted: true, sandbox: "stopped" } };
			},
		};
	}

	test("happy path: every assertion passes and the probe session is deleted", async () => {
		const log = [];
		const result = await runRealTurnProbe(happyClient(log), options());
		expect(result.status).toBe("run");
		expect(result.checks.every((c) => c.status === "pass")).toBe(true);
		expect(result.checks.map((c) => c.id)).toContain("no_leaked_sandbox");
		expect(log.at(-1)[0]).toBe("delete");
		// The probe session is titled as validation litter and runs on vercel.
		expect(log[0][1]).toMatchObject({
			title: "validation: real-turn probe 2026-07-07T00:00:00Z",
			provider: "vercel",
		});
	});

	test("routes missing on the target is a stage skip and creates nothing to clean", async () => {
		const result = await runRealTurnProbe(
			{ createSession: async () => ({ status: 404 }) },
			options(),
		);
		expect(result).toMatchObject({ status: "skip" });
	});

	test("a rejected chat still tears the session down", async () => {
		const log = [];
		const client = {
			...happyClient(log),
			sendChat: async () => ({ status: 500, body: { error: "boom" } }),
		};
		const result = await runRealTurnProbe(client, options());
		const ids = result.checks.map((c) => c.id);
		expect(ids).toContain("turn_started");
		expect(result.checks.find((c) => c.id === "turn_started").status).toBe("fail");
		expect(log.some(([op]) => op === "delete")).toBe(true);
	});

	test("a client fault mid-poll still tears the session down, then rethrows", async () => {
		const log = [];
		const client = {
			...happyClient(log),
			getSession: async () => {
				throw new Error("network died");
			},
		};
		await expect(runRealTurnProbe(client, options())).rejects.toThrow("network died");
		expect(log.some(([op]) => op === "delete")).toBe(true);
	});

	test("a failed teardown is reported as the leak check, not thrown", async () => {
		const client = {
			...happyClient(),
			deleteSession: async () => {
				throw new Error("delete route down");
			},
		};
		const result = await runRealTurnProbe(client, options());
		const leak = result.checks.find((c) => c.id === "no_leaked_sandbox");
		expect(leak.status).toBe("fail");
		expect(leak.detail).toMatch(/delete route down/);
	});

	test("a turn that never closes fails turn_done after the deadline (and still deletes)", async () => {
		const log = [];
		let t = 0;
		const client = {
			...happyClient(log),
			getSession: async () => ({
				status: 200,
				body: { session: { parked: false }, events: [ev("assistant", "status", "Booting Claude Code in sandbox")] },
			}),
		};
		const result = await runRealTurnProbe(
			client,
			options({ now: () => (t += 6), deadlineMs: 20 }),
		);
		const done = result.checks.find((c) => c.id === "turn_done");
		expect(done.status).toBe("fail");
		expect(log.some(([op]) => op === "delete")).toBe(true);
	});
});
