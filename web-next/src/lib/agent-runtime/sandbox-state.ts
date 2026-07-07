/*
 * The session's sandbox lifecycle, truthfully (#753): resolve the parked
 * Vercel sandbox's real status into the three states the masthead surfaces
 * (live / parked / none), and stop a live one on request. Point-in-time
 * facts checked against the platform, never inferred from what the UI hopes
 * is true — the same honesty contract as the terminal drawer's
 * `resolveLiveSandbox` (#752), with which this shares the name derivation
 * and the "a stale/absent handle reads as none, calmly" behavior.
 *
 * Why stop is the only control: the Vercel sandbox API has no pause/freeze —
 * `Sandbox.stop()` ends the VM (optionally snapshotting), and resumption
 * happens implicitly on the next `Sandbox.get`/turn, not as a user verb. A
 * pause button would be a fake; stop is real, so stop is what ships.
 */
import { sessionSandboxName } from "./vercel-provider";
import type { Session } from "../db/sessions";

/** The slice of @vercel/sandbox's Sandbox the lifecycle path touches. */
export interface LifecycleSandbox {
	name: string;
	/** "failed" | "aborted" | "pending" | "running" | "stopping" | "stopped" | "snapshotting" */
	status: string;
	stop(): Promise<unknown>;
}

/** Fetch-by-name, throwing when the sandbox is gone. Injected for tests. */
export type GetLifecycleSandbox = (name: string) => Promise<LifecycleSandbox>;

/**
 * live: a VM is up (or coming up) — the terminal can attach, the next turn
 * resumes warm. parked: the VM is stopped/snapshotting; nothing is running,
 * but the platform may restore it on the next turn. none: no sandbox exists
 * for this session (never started, expired, or failed) — `detail` says why.
 */
export type SandboxState =
	| { state: "live" }
	| { state: "parked"; detail: string }
	| { state: "none"; detail: string };

const LIVE_STATUSES: ReadonlySet<string> = new Set(["running", "pending"]);
const PARKED_STATUSES: ReadonlySet<string> = new Set([
	"stopping",
	"stopped",
	"snapshotting",
]);

async function defaultGetSandbox(name: string): Promise<LifecycleSandbox> {
	const { Sandbox } = await import("@vercel/sandbox");
	const token = process.env.VERCEL_TOKEN;
	const teamId = process.env.VERCEL_TEAM_ID;
	const projectId = process.env.VERCEL_PROJECT_ID;
	return (await Sandbox.get({
		name,
		// A status check must never resurrect a parked sandbox.
		resume: false,
		...(token && teamId && projectId ? { token, teamId, projectId } : {}),
	})) as unknown as LifecycleSandbox;
}

/** The session's sandbox state, checked against the platform right now. */
export async function resolveSandboxState(
	session: Pick<Session, "claudeSessionId" | "resumeState">,
	getSandbox: GetLifecycleSandbox = defaultGetSandbox,
): Promise<SandboxState> {
	if (!session.claudeSessionId || !session.resumeState) {
		return { state: "none", detail: "no turn has started a sandbox yet" };
	}
	let sandbox: LifecycleSandbox;
	try {
		sandbox = await getSandbox(sessionSandboxName(session.claudeSessionId));
	} catch {
		return { state: "none", detail: "the session's sandbox has expired" };
	}
	if (LIVE_STATUSES.has(sandbox.status)) return { state: "live" };
	if (PARKED_STATUSES.has(sandbox.status)) {
		return { state: "parked", detail: sandbox.status };
	}
	return { state: "none", detail: `the session's sandbox is ${sandbox.status}` };
}

/**
 * Stops the session's sandbox if a VM is actually up, then reports the
 * post-stop state. Idempotent from the caller's view: stopping a session
 * whose sandbox is already parked or gone changes nothing and returns the
 * honest current state — no error for asking twice. The parked resume
 * handle stays on the session row: the next turn's resume path already
 * treats an unresumable handle as "boot fresh", so a stale handle is
 * self-healing, and clearing it here would discard a restorable snapshot.
 */
export async function stopSessionSandbox(
	session: Pick<Session, "claudeSessionId" | "resumeState">,
	getSandbox: GetLifecycleSandbox = defaultGetSandbox,
): Promise<SandboxState> {
	if (!session.claudeSessionId || !session.resumeState) {
		return { state: "none", detail: "no turn has started a sandbox yet" };
	}
	let sandbox: LifecycleSandbox;
	try {
		sandbox = await getSandbox(sessionSandboxName(session.claudeSessionId));
	} catch {
		return { state: "none", detail: "the session's sandbox has expired" };
	}
	if (!LIVE_STATUSES.has(sandbox.status)) {
		// Nothing running to stop — report what is actually there.
		return PARKED_STATUSES.has(sandbox.status)
			? { state: "parked", detail: sandbox.status }
			: { state: "none", detail: `the session's sandbox is ${sandbox.status}` };
	}
	await sandbox.stop();
	return { state: "parked", detail: "stopped" };
}
