/*
 * Tears down the LIVE sandbox a session's last turn parked (#818's no-leak
 * contract): resolve the parked sandbox by the same name derivation the
 * resume path uses, stop it if it is still running, and report an honest
 * disposition. Session deletion (the DELETE route) calls this BEFORE removing
 * rows — a stop failure keeps the session (and its resume handle) so a retry
 * can still reach the sandbox, rather than deleting the only pointer to a
 * machine that is still billing. The Vercel dependency is injected for tests.
 */
import type { Session } from "../db/sessions";
import { sessionSandboxName } from "./vercel-provider";

/** The slice of @vercel/sandbox's Sandbox the release path touches. */
export interface StoppableSandbox {
	status: string;
	stop(): Promise<unknown>;
}

/** Fetch-by-name, throwing when the sandbox is gone. Injected for tests. */
export type GetStoppableSandbox = (name: string) => Promise<StoppableSandbox>;

export type SandboxRelease =
	/** The session never parked a sandbox — nothing to release. */
	| { disposition: "none" }
	/** A handle existed but the sandbox is already gone or not running. */
	| { disposition: "expired"; detail: string }
	/** A live sandbox was found and stopped. */
	| { disposition: "stopped" }
	/** A live sandbox was found but could not be stopped — it may still bill. */
	| { disposition: "stop-failed"; detail: string };

/** Mirrors sandbox-terminal.ts: `Sandbox.get` succeeds for dead sandboxes too. */
const ALIVE_STATUSES: ReadonlySet<string> = new Set(["running", "pending"]);

async function defaultGetSandbox(name: string): Promise<StoppableSandbox> {
	const { Sandbox } = await import("@vercel/sandbox");
	const token = process.env.VERCEL_TOKEN;
	const teamId = process.env.VERCEL_TEAM_ID;
	const projectId = process.env.VERCEL_PROJECT_ID;
	return (await Sandbox.get({
		name,
		// Looking for the sandbox must not resurrect a stopped one.
		resume: false,
		...(token && teamId && projectId ? { token, teamId, projectId } : {}),
	})) as unknown as StoppableSandbox;
}

/**
 * Stops the session's parked sandbox, if any. Every outcome is a disposition,
 * never a throw — the caller decides what each one means (the DELETE route
 * treats `stop-failed` as a reason not to delete; everything else is clear).
 */
export async function releaseParkedSandbox(
	session: Pick<Session, "claudeSessionId" | "resumeState">,
	getSandbox: GetStoppableSandbox = defaultGetSandbox,
): Promise<SandboxRelease> {
	if (!session.claudeSessionId || !session.resumeState) {
		return { disposition: "none" };
	}
	let sandbox: StoppableSandbox;
	try {
		sandbox = await getSandbox(sessionSandboxName(session.claudeSessionId));
	} catch (error) {
		const detail = error instanceof Error ? error.message : String(error);
		return { disposition: "expired", detail };
	}
	if (!ALIVE_STATUSES.has(sandbox.status)) {
		return { disposition: "expired", detail: `sandbox is ${sandbox.status}` };
	}
	try {
		await sandbox.stop();
		return { disposition: "stopped" };
	} catch (error) {
		const detail = error instanceof Error ? error.message : String(error);
		return { disposition: "stop-failed", detail };
	}
}
