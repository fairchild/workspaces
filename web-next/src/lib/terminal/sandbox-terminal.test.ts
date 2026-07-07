import { describe, expect, test } from "vitest";
import { sessionSandboxName, TERMINAL_PORT } from "../agent-runtime/vercel-provider";
import { terminalPathToken } from "./path-token";
import {
	ensureTerminal,
	type FinishedCommand,
	resolveLiveSandbox,
	type TerminalSandbox,
	TerminalUnsupportedError,
} from "./sandbox-terminal";

function finished(exitCode: number, stdout = "", stderr = ""): FinishedCommand {
	return {
		exitCode,
		stdout: async () => stdout,
		stderr: async () => stderr,
	};
}

interface FakeOptions {
	status?: string;
	/** The running ttyd's command line, or null when none is running. */
	ttydCmdline?: string | null;
	hasTerminalPort?: boolean;
}

function fakeSandbox(options: FakeOptions = {}) {
	const commands: { cmd: string; args?: string[]; detached?: boolean }[] = [];
	let ttydCmdline = options.ttydCmdline ?? null;
	const sandbox: TerminalSandbox = {
		name: "ai-sdk-harness-session-abc",
		status: options.status ?? "running",
		domain(port: number) {
			if (options.hasTerminalPort === false)
				throw new Error(`port ${port} is not exposed`);
			return `https://sb-abc-${port}.vercel.run`;
		},
		currentSession: () => ({ sessionId: "vm-session-1" }),
		async runCommand(params) {
			commands.push(params);
			const script = params.args?.[1] ?? "";
			if (script.includes("pgrep")) {
				// Model the attestation probe: a running ttyd counts only when
				// its command line carries the greps' -b and -p patterns; a
				// non-matching one is killed by the probe.
				const patterns = [...script.matchAll(/grep -qF -- "([^"]+)"/g)].map(
					(m) => m[1],
				);
				if (
					ttydCmdline !== null &&
					patterns.every((p) => ttydCmdline?.includes(p))
				) {
					return finished(0, "attested");
				}
				ttydCmdline = null; // probe killed the impostor (if any)
				return finished(0, "absent");
			}
			if (params.cmd.endsWith("/ttyd")) {
				ttydCmdline = `ttyd ${(params.args ?? []).join(" ")}`;
			}
			return finished(0);
		},
	};
	return { sandbox, commands, currentTtyd: () => ttydCmdline };
}

const parked = { claudeSessionId: "abc", resumeState: "{}" };

describe("resolveLiveSandbox", () => {
	test("a session with no parked handle has no sandbox to attach to", async () => {
		const result = await resolveLiveSandbox(
			{ claudeSessionId: null, resumeState: null },
			async () => {
				throw new Error("must not be called");
			},
		);
		expect(result).toEqual({
			state: "none",
			reason: "no turn has started a sandbox yet",
		});
	});

	test("looks up exactly the session's own sandbox name", async () => {
		const requested: string[] = [];
		await resolveLiveSandbox(parked, async (name) => {
			requested.push(name);
			return fakeSandbox().sandbox;
		});
		expect(requested).toEqual([sessionSandboxName("abc")]);
	});

	test("an expired (missing) sandbox resolves to none, not an error", async () => {
		const result = await resolveLiveSandbox(parked, async () => {
			throw new Error("not_found");
		});
		expect(result).toEqual({
			state: "none",
			reason: "the session's sandbox has expired",
		});
	});

	test("a stopped sandbox is not live", async () => {
		const { sandbox } = fakeSandbox({ status: "stopped" });
		const result = await resolveLiveSandbox(parked, async () => sandbox);
		expect(result).toEqual({
			state: "none",
			reason: "the session's sandbox is stopped",
		});
	});

	test("a running sandbox resolves live", async () => {
		const { sandbox } = fakeSandbox();
		const result = await resolveLiveSandbox(parked, async () => sandbox);
		expect(result).toEqual({ state: "live", sandbox });
	});
});

describe("ensureTerminal", () => {
	test("starts ttyd behind the HMAC base-path and returns the wss URL", async () => {
		const { sandbox, commands } = fakeSandbox();
		const { wsUrl } = await ensureTerminal(sandbox);
		const token = terminalPathToken("vm-session-1");
		expect(wsUrl).toBe(`wss://sb-abc-${TERMINAL_PORT}.vercel.run/${token}/ws`);
		const start = commands.find((c) => c.cmd.endsWith("/ttyd"));
		expect(start?.detached).toBe(true);
		expect(start?.args).toContain(`/${token}`);
		// tmux keeps the shell state across reconnects within a sandbox.
		expect(start?.args?.join(" ")).toContain("new-session -A -s shell");
	});

	test("a ttyd attesting the current token is left alone (idempotent reconnect)", async () => {
		const token = terminalPathToken("vm-session-1");
		const { sandbox, commands } = fakeSandbox({
			ttydCmdline: `ttyd -W -p ${TERMINAL_PORT} -b /${token} tmux new-session -A -s shell`,
		});
		await ensureTerminal(sandbox);
		expect(commands.filter((c) => c.cmd.endsWith("/ttyd"))).toHaveLength(0);
	});

	test("a ttyd serving a stale token is replaced, not blessed", async () => {
		const { sandbox, currentTtyd } = fakeSandbox({
			ttydCmdline: `ttyd -W -p ${TERMINAL_PORT} -b /0000stale0000 tmux new-session -A -s shell`,
		});
		const { wsUrl } = await ensureTerminal(sandbox);
		const token = terminalPathToken("vm-session-1");
		expect(wsUrl).toContain(`/${token}/ws`);
		expect(currentTtyd()).toContain(`-b /${token}`);
		expect(currentTtyd()).not.toContain("stale");
	});

	test("a sandbox that never exposed the terminal port is unsupported", async () => {
		const { sandbox } = fakeSandbox({ hasTerminalPort: false });
		await expect(ensureTerminal(sandbox)).rejects.toBeInstanceOf(
			TerminalUnsupportedError,
		);
	});
});
