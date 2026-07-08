/*
 * The session's sandbox lifecycle, truthfully (#753): resolve the parked
 * Vercel sandbox's real status into the three states the masthead surfaces
 * (live / parked / none), stop a live one on request, and opportunistically
 * stop warm parked VMs after a short idle window. Point-in-time facts are
 * checked against the platform, never inferred from what the UI hopes is true
 * — the same honesty contract as the terminal drawer's `resolveLiveSandbox`
 * (#752), with which this shares the name derivation and the "a stale/absent
 * handle reads as none, calmly" behavior.
 *
 * Why stop is the only control: the Vercel sandbox API has no pause/freeze —
 * `Sandbox.stop()` ends the VM (optionally snapshotting), and resumption
 * happens implicitly on the next `Sandbox.get`/turn, not as a user verb. A
 * pause button would be a fake; stop is real, so stop is what ships.
 */
import { sessionSandboxName } from "./vercel-provider";
import type { DatabaseHandle } from "../db/client";
import { readEvents, type Session } from "../db/sessions";
import type { ProjectedEvent } from "../transcript/project-events";

/**
 * Adaptive idle-stop window for parked live VMs (#970). Five minutes keeps
 * quick follow-up turns warm while cutting the old 30-minute idle billing
 * window by roughly 6x when the session page is open and refreshing state.
 */
export const ADAPTIVE_IDLE_STOP_MS = 5 * 60 * 1000;

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

export interface ResolveSandboxStateOptions {
	now?: Date;
	idleStopAfterMs?: number;
	currentTurnSettled?: boolean;
}

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
	session: Pick<Session, "claudeSessionId" | "resumeState"> &
		Partial<Pick<Session, "lastActivityAt">>,
	getSandbox: GetLifecycleSandbox = defaultGetSandbox,
	options: ResolveSandboxStateOptions = {},
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
	if (LIVE_STATUSES.has(sandbox.status)) {
		if (shouldStopForIdle(session, options)) {
			try {
				await sandbox.stop();
				return { state: "parked", detail: "stopped" };
			} catch (error) {
				console.warn(
					`[sandbox-state] adaptive idle-stop failed for ${sandbox.name}: ${errorMessage(error)}`,
				);
			}
		}
		return { state: "live" };
	}
	if (PARKED_STATUSES.has(sandbox.status)) {
		return { state: "parked", detail: sandbox.status };
	}
	return { state: "none", detail: `the session's sandbox is ${sandbox.status}` };
}

function shouldStopForIdle(
	session: Partial<Pick<Session, "lastActivityAt">>,
	options: ResolveSandboxStateOptions,
): boolean {
	if (options.currentTurnSettled !== true) return false;
	if (!session.lastActivityAt) return false;
	const lastActivityMs = Date.parse(session.lastActivityAt);
	if (!Number.isFinite(lastActivityMs)) return false;
	const idleStopAfterMs = options.idleStopAfterMs ?? ADAPTIVE_IDLE_STOP_MS;
	if (idleStopAfterMs <= 0) return true;
	const nowMs = (options.now ?? new Date()).getTime();
	return nowMs - lastActivityMs >= idleStopAfterMs;
}

/**
 * Idle-stop invariant (#970): never stop a sandbox while the current turn is
 * unsettled. The durable `session_events` log is the authority because the
 * polling state GET may land on a different Vercel instance than the detached
 * ingest loop. A turn is settled only when assistant events after the last
 * user event contain the terminal `done` chunk that turn-ingest also appends
 * for error/abort paths.
 *
 * If a runner crashes and never appends `done`, this deliberately leaves the
 * sandbox live until the platform's SANDBOX_TIMEOUT_MS cap (30 minutes).
 */
export function isCurrentTurnSettled(
	events: readonly Pick<ProjectedEvent, "seq" | "role" | "chunk">[],
): boolean {
	let lastUserSeq = 0;
	for (const event of events) {
		if (event.role === "user") lastUserSeq = event.seq;
	}
	if (lastUserSeq === 0) return true;
	return events.some(
		(event) =>
			event.seq > lastUserSeq &&
			event.role === "assistant" &&
			event.chunk.type === "done",
	);
}

/** Reads the durable log and classifies whether the session's current turn settled. */
export async function readCurrentTurnSettled(
	handle: DatabaseHandle,
	sessionId: string,
): Promise<boolean> {
	return isCurrentTurnSettled(await readEvents(handle, sessionId));
}

function errorMessage(error: unknown): string {
	if (error instanceof Error) return error.message;
	return String(error);
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
