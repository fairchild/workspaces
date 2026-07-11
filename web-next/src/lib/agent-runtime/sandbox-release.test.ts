import { describe, expect, test } from "vitest";
import { releaseParkedSandbox, type StoppableSandbox } from "./sandbox-release";
import { sessionSandboxName } from "./vercel-provider";

const parked = { claudeSessionId: "harness-1", resumeState: "{}" };

function sandbox(status: string, stop: () => Promise<unknown> = async () => {}) {
	return { status, stop } satisfies StoppableSandbox;
}

describe("releaseParkedSandbox", () => {
	test("a host resume handle is not treated as a Vercel sandbox", async () => {
		let lookedUp = false;
		const release = await releaseParkedSandbox(
			{ ...parked, provider: "host" },
			async () => {
				lookedUp = true;
				return sandbox("running");
			},
		);
		expect(release).toEqual({ disposition: "none" });
		expect(lookedUp).toBe(false);
	});

	test("a session that never parked has nothing to release", async () => {
		expect(
			await releaseParkedSandbox({ claudeSessionId: null, resumeState: null }),
		).toEqual({ disposition: "none" });
		expect(
			await releaseParkedSandbox({ claudeSessionId: "h", resumeState: null }),
		).toEqual({ disposition: "none" });
	});

	test("looks up the sandbox by the resume path's own name derivation", async () => {
		let requested: string | undefined;
		await releaseParkedSandbox(parked, async (name) => {
			requested = name;
			return sandbox("running");
		});
		expect(requested).toBe(sessionSandboxName("harness-1"));
	});

	test("a live sandbox is stopped", async () => {
		let stopped = false;
		const release = await releaseParkedSandbox(parked, async () =>
			sandbox("running", async () => {
				stopped = true;
			}),
		);
		expect(release).toEqual({ disposition: "stopped" });
		expect(stopped).toBe(true);
	});

	test("a gone or non-running sandbox is expired, never a throw", async () => {
		expect(
			await releaseParkedSandbox(parked, async () => {
				throw new Error("not found");
			}),
		).toEqual({ disposition: "expired", detail: "not found" });
		expect(
			await releaseParkedSandbox(parked, async () => sandbox("stopped")),
		).toEqual({ disposition: "expired", detail: "sandbox is stopped" });
	});

	test("a non-404 lookup failure is unreachable, not expired — the sandbox may be alive", async () => {
		expect(
			await releaseParkedSandbox(parked, async () => {
				throw new Error("ETIMEDOUT: request timed out");
			}),
		).toEqual({ disposition: "unreachable", detail: "ETIMEDOUT: request timed out" });
		// A structured 404 still reads as gone.
		expect(
			await releaseParkedSandbox(parked, async () => {
				const err = new Error("Status code 404") as Error & { status: number };
				err.status = 404;
				throw err;
			}),
		).toEqual({ disposition: "expired", detail: "Status code 404" });
	});

	test("a stop failure is reported, not swallowed — the caller decides", async () => {
		const release = await releaseParkedSandbox(parked, async () =>
			sandbox("running", async () => {
				throw new Error("api timeout");
			}),
		);
		expect(release).toEqual({ disposition: "stop-failed", detail: "api timeout" });
	});
});
