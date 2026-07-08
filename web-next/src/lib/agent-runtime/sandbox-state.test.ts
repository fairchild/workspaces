/*
 * The truthfulness contract of the sandbox lifecycle (#753): every platform
 * status maps to exactly one of live/parked/none, an absent or unreachable
 * sandbox reads calmly as none, and stop only ever calls the platform when a
 * VM is actually up — an already-parked or gone sandbox is reported, not
 * "stopped" again.
 */
import { describe, expect, test, vi } from "vitest";
import {
	ADAPTIVE_IDLE_STOP_MS,
	type LifecycleSandbox,
	resolveSandboxState,
	stopSessionSandbox,
} from "./sandbox-state";
import { sessionSandboxName } from "./vercel-provider";

const PARKED_SESSION = {
	claudeSessionId: "harness-1",
	resumeState: '{"parked":true}',
};
const NOW = new Date("2026-07-08T17:00:00.000Z");

function sandboxWith(status: string): LifecycleSandbox & { stop: ReturnType<typeof vi.fn> } {
	return {
		name: sessionSandboxName("harness-1"),
		status,
		stop: vi.fn(async () => ({})),
	};
}

describe("resolveSandboxState", () => {
	test("a session that never started a sandbox is none", async () => {
		const state = await resolveSandboxState(
			{ claudeSessionId: null, resumeState: null },
			async () => {
				throw new Error("must not be called");
			},
		);
		expect(state).toEqual({
			state: "none",
			detail: "no turn has started a sandbox yet",
		});
	});

	test("an unreachable (expired) sandbox is none, calmly", async () => {
		const state = await resolveSandboxState(PARKED_SESSION, async () => {
			throw new Error("sandbox_not_found");
		});
		expect(state).toEqual({
			state: "none",
			detail: "the session's sandbox has expired",
		});
	});

	test.each(["running", "pending"])("%s reads as live", async (status) => {
		const state = await resolveSandboxState(PARKED_SESSION, async () =>
			sandboxWith(status),
		);
		expect(state).toEqual({ state: "live" });
	});

	test("a live sandbox inside the adaptive idle window stays warm", async () => {
		const sandbox = sandboxWith("running");
		const state = await resolveSandboxState(
			{
				...PARKED_SESSION,
				lastActivityAt: new Date(
					NOW.getTime() - ADAPTIVE_IDLE_STOP_MS + 1_000,
				).toISOString(),
			},
			async () => sandbox,
			{ now: NOW },
		);

		expect(sandbox.stop).not.toHaveBeenCalled();
		expect(state).toEqual({ state: "live" });
	});

	test("a live sandbox past the adaptive idle window is stopped and reported parked", async () => {
		const sandbox = sandboxWith("running");
		const state = await resolveSandboxState(
			{
				...PARKED_SESSION,
				lastActivityAt: new Date(
					NOW.getTime() - ADAPTIVE_IDLE_STOP_MS - 1_000,
				).toISOString(),
			},
			async () => sandbox,
			{ now: NOW },
		);

		expect(sandbox.stop).toHaveBeenCalledTimes(1);
		expect(state).toEqual({ state: "parked", detail: "stopped" });
	});

	test("adaptive idle-stop failures leave the sandbox live and do not throw", async () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
		const sandbox = sandboxWith("running");
		sandbox.stop.mockRejectedValueOnce(new Error("api timeout"));

		const state = await resolveSandboxState(
			{
				...PARKED_SESSION,
				lastActivityAt: new Date(
					NOW.getTime() - ADAPTIVE_IDLE_STOP_MS - 1_000,
				).toISOString(),
			},
			async () => sandbox,
			{ now: NOW },
		);

		expect(sandbox.stop).toHaveBeenCalledTimes(1);
		expect(state).toEqual({ state: "live" });
		expect(warn).toHaveBeenCalledWith(
			expect.stringContaining("adaptive idle-stop failed"),
		);
		warn.mockRestore();
	});

	test.each(["stopping", "stopped", "snapshotting"])(
		"%s reads as parked",
		async (status) => {
			const state = await resolveSandboxState(PARKED_SESSION, async () =>
				sandboxWith(status),
			);
			expect(state).toEqual({ state: "parked", detail: status });
		},
	);

	test.each(["failed", "aborted"])("%s reads as none with the reason", async (status) => {
		const state = await resolveSandboxState(PARKED_SESSION, async () =>
			sandboxWith(status),
		);
		expect(state).toEqual({
			state: "none",
			detail: `the session's sandbox is ${status}`,
		});
	});

	test("looks the sandbox up by the session's own parked name", async () => {
		const getSandbox = vi.fn(async () => sandboxWith("running"));
		await resolveSandboxState(PARKED_SESSION, getSandbox);
		expect(getSandbox).toHaveBeenCalledWith(sessionSandboxName("harness-1"));
	});
});

describe("stopSessionSandbox", () => {
	test("stops a running VM and reports it parked", async () => {
		const sandbox = sandboxWith("running");
		const state = await stopSessionSandbox(PARKED_SESSION, async () => sandbox);
		expect(sandbox.stop).toHaveBeenCalledTimes(1);
		expect(state).toEqual({ state: "parked", detail: "stopped" });
	});

	test("an already-parked sandbox is reported, never stop()ed again", async () => {
		const sandbox = sandboxWith("stopped");
		const state = await stopSessionSandbox(PARKED_SESSION, async () => sandbox);
		expect(sandbox.stop).not.toHaveBeenCalled();
		expect(state).toEqual({ state: "parked", detail: "stopped" });
	});

	test("a gone sandbox is none; nothing is called", async () => {
		const state = await stopSessionSandbox(PARKED_SESSION, async () => {
			throw new Error("sandbox_not_found");
		});
		expect(state).toEqual({
			state: "none",
			detail: "the session's sandbox has expired",
		});
	});

	test("a session with no sandbox handle is none; the platform is never asked", async () => {
		const getSandbox = vi.fn();
		const state = await stopSessionSandbox(
			{ claudeSessionId: null, resumeState: null },
			getSandbox,
		);
		expect(getSandbox).not.toHaveBeenCalled();
		expect(state.state).toBe("none");
	});
});
