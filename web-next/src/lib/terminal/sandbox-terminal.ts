/*
 * Attaches a terminal to a session's LIVE sandbox (#752): resolves the Vercel
 * sandbox the session's last turn parked (by the same name derivation the
 * harness resume path uses), verifies it is actually running, ensures ttyd is
 * serving behind its HMAC base-path, and composes the WebSocket URL.
 *
 * Attach-only by design: `resume: false` on the lookup, so opening the drawer
 * never boots or resumes a VM. A parked/expired session honestly reports
 * "none" — the sandbox is the product of a turn, and the drawer attaches to
 * it; it doesn't manufacture one. The Vercel dependency is injected
 * (GetSandbox) so the resolution and ttyd logic are unit-testable.
 */
import {
	sessionSandboxName,
	TERMINAL_PORT,
	WORKSPACE_DIR,
} from "../agent-runtime/vercel-provider";
import type { Session } from "../db/sessions";
import { TERMINAL_INSTALL_SCRIPT, TMUX_BIN, TTYD_BIN } from "./install";
import { terminalPathToken } from "./path-token";

/** @vercel/sandbox v2 command handle: exit code property, output as methods. */
export interface FinishedCommand {
	exitCode: number;
	stdout(): Promise<string>;
	stderr(): Promise<string>;
}

/** The slice of @vercel/sandbox's Sandbox the terminal path touches. */
export interface TerminalSandbox {
	name: string;
	status: string;
	domain(port: number): string;
	currentSession(): { sessionId: string };
	runCommand(params: {
		cmd: string;
		args?: string[];
		cwd?: string;
		detached?: boolean;
	}): Promise<FinishedCommand>;
}

/** Fetch-by-name, throwing when the sandbox is gone. Injected for tests. */
export type GetSandbox = (name: string) => Promise<TerminalSandbox>;

export type LiveSandboxResolution =
	| { state: "live"; sandbox: TerminalSandbox }
	| { state: "none"; reason: string };

/** `Sandbox.get` succeeds for stopped/failed sandboxes too — check status. */
const ALIVE_STATUSES: ReadonlySet<string> = new Set(["running", "pending"]);

async function defaultGetSandbox(name: string): Promise<TerminalSandbox> {
	const { Sandbox } = await import("@vercel/sandbox");
	const token = process.env.VERCEL_TOKEN;
	const teamId = process.env.VERCEL_TEAM_ID;
	const projectId = process.env.VERCEL_PROJECT_ID;
	return (await Sandbox.get({
		name,
		// Attach-only: looking at a stopped sandbox must not resurrect it.
		resume: false,
		...(token && teamId && projectId ? { token, teamId, projectId } : {}),
	})) as unknown as TerminalSandbox;
}

/**
 * The session's live sandbox, or a calm "none" with the honest reason. Bound
 * to the session's own parked handle — there is no path to another session's
 * sandbox from here.
 */
export async function resolveLiveSandbox(
	session: Pick<Session, "claudeSessionId" | "resumeState">,
	getSandbox: GetSandbox = defaultGetSandbox,
): Promise<LiveSandboxResolution> {
	if (!session.claudeSessionId || !session.resumeState) {
		return { state: "none", reason: "no turn has started a sandbox yet" };
	}
	let sandbox: TerminalSandbox;
	try {
		sandbox = await getSandbox(sessionSandboxName(session.claudeSessionId));
	} catch {
		return { state: "none", reason: "the session's sandbox has expired" };
	}
	if (!ALIVE_STATUSES.has(sandbox.status)) {
		return {
			state: "none",
			reason: `the session's sandbox is ${sandbox.status}`,
		};
	}
	return { state: "live", sandbox };
}

/** Sandboxes created before TERMINAL_PORT was declared can't publish a shell. */
export class TerminalUnsupportedError extends Error {
	constructor() {
		super(
			"this sandbox predates terminal support — the next fresh turn will boot one that has it",
		);
		this.name = "TerminalUnsupportedError";
	}
}

/**
 * The reuse probe: a running ttyd counts only if its command line attests the
 * expected `-b /<token>` and `-p <port>` — a process that merely shares the
 * name (stale token after secret rotation, or something else that bound the
 * port) is killed and replaced, so the published port is never served outside
 * the current HMAC gate (codex review finding, gpt-5.5 xhigh). Token is hex
 * and port digits, so both embed safely in the grep -F patterns.
 */
function ttydProbeScript(token: string, port: number): string {
	return [
		`pid=$(pgrep -x ttyd | head -n1 || true)`,
		`if [ -n "$pid" ] && tr '\\0' ' ' < /proc/$pid/cmdline | grep -qF -- "-b /${token}" && tr '\\0' ' ' < /proc/$pid/cmdline | grep -qF -- "-p ${port}"; then`,
		`  echo attested`,
		`else`,
		`  if [ -n "$pid" ]; then`,
		`    kill "$pid" 2>/dev/null || true`,
		`    for i in 1 2 3 4 5 6 7 8; do pgrep -x ttyd >/dev/null 2>&1 || break; sleep 0.25; done`,
		`  fi`,
		`  echo absent`,
		`fi`,
	].join("\n");
}

/**
 * Ensures ttyd serves the sandbox's shell behind its HMAC base-path and
 * returns the WebSocket URL. Idempotent: a ttyd whose command line attests
 * the current token and port is left alone (the token is stable — it's
 * derived from the VM session id); anything else is replaced. The shell is
 * `tmux new-session -A -s shell`, so disconnect/reconnect within a sandbox
 * lands back in the same shell state (the tmux acceptance criterion).
 */
export async function ensureTerminal(
	sandbox: TerminalSandbox,
): Promise<{ wsUrl: string }> {
	let domain: string;
	try {
		domain = sandbox.domain(TERMINAL_PORT);
	} catch {
		throw new TerminalUnsupportedError();
	}
	const token = terminalPathToken(sandbox.currentSession().sessionId);
	const probe = await sandbox.runCommand({
		cmd: "bash",
		args: ["-c", ttydProbeScript(token, TERMINAL_PORT)],
	});
	if (!(await probe.stdout()).includes("attested")) {
		// Fallback install for sandboxes built from a pre-terminal template
		// snapshot; a no-op when the bootstrap already baked the binaries in.
		const install = await sandbox.runCommand({
			cmd: "bash",
			args: ["-c", TERMINAL_INSTALL_SCRIPT],
		});
		if (install.exitCode !== 0) {
			const stderr = await install.stderr();
			throw new Error(
				`terminal install failed (exit ${install.exitCode}): ${stderr.slice(0, 300)}`,
			);
		}
		await sandbox.runCommand({
			cmd: TTYD_BIN,
			// -W: writable; base-path is the HMAC gate — ttyd serves its
			// WebSocket only under /<token>/ws.
			args: [
				"-W",
				"-p",
				String(TERMINAL_PORT),
				"-b",
				`/${token}`,
				TMUX_BIN,
				"new-session",
				"-A",
				"-s",
				"shell",
			],
			cwd: WORKSPACE_DIR,
			detached: true,
		});
	}
	// http → ws, https → wss (the shared prefix makes one replace cover both).
	const wss = domain.replace(/^http/, "ws").replace(/\/$/, "");
	return { wsUrl: `${wss}/${token}/ws` };
}
