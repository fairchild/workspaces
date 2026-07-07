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
	ttydRunning?: boolean;
	hasTerminalPort?: boolean;
}

function fakeSandbox(options: FakeOptions = {}) {
	const commands: { cmd: string; args?: string[]; detached?: boolean }[] = [];
	let ttydRunning = options.ttydRunning ?? false;
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
			if (params.args?.[1]?.includes("pgrep")) {
				return finished(0, ttydRunning ? "running" : "stopped");
			}
			if (params.cmd.endsWith("/ttyd")) ttydRunning = true;
			return finished(0);
		},
	};
	return { sandbox, commands };
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

	test("a running ttyd is left alone (idempotent reconnect)", async () => {
		const { sandbox, commands } = fakeSandbox({ ttydRunning: true });
		await ensureTerminal(sandbox);
		expect(commands.filter((c) => c.cmd.endsWith("/ttyd"))).toHaveLength(0);
	});

	test("a sandbox that never exposed the terminal port is unsupported", async () => {
		const { sandbox } = fakeSandbox({ hasTerminalPort: false });
		await expect(ensureTerminal(sandbox)).rejects.toBeInstanceOf(
			TerminalUnsupportedError,
		);
	});
});
