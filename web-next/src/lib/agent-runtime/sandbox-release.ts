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
	| { disposition: "stop-failed"; detail: string }
	/** The lookup itself failed for a non-404 reason (API timeout/auth/rate
	 * limit) — the sandbox may well be alive, we just can't tell. */
	| { disposition: "unreachable"; detail: string };

function asText(value: unknown): string {
	if (typeof value === "string") return value;
	try {
		return JSON.stringify(value) ?? String(value);
	} catch {
		return String(value);
	}
}

function errorDetail(error: unknown): string {
	return error instanceof Error ? error.message : asText(error);
}

/**
 * Whether a `Sandbox.get` failure means "no such sandbox" (vs a transient API
 * fault). The Vercel APIError's `message` is only the status line; the reason
 * can live in `json`/`text` — same matching posture as the provider's
 * isNameCollision.
 */
function isNotFound(error: unknown): boolean {
	const e = error as { status?: unknown; message?: unknown; text?: unknown; json?: unknown };
	if (e?.status === 404) return true;
	const haystack = [asText(e?.message ?? ""), asText(e?.text ?? ""), asText(e?.json ?? "")].join(" ");
	return /not[ _-]?found|status code 404|\b404\b/i.test(haystack);
}

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
	session: Pick<Session, "claudeSessionId" | "resumeState" | "provider">,
	getSandbox: GetStoppableSandbox = defaultGetSandbox,
): Promise<SandboxRelease> {
	// Host turns exit after each invocation. Their persisted resume handle names
	// a Claude conversation + working copy, not a live Vercel sandbox.
	if (session.provider === "host") return { disposition: "none" };
	if (!session.claudeSessionId || !session.resumeState) {
		return { disposition: "none" };
	}
	let sandbox: StoppableSandbox;
	try {
		sandbox = await getSandbox(sessionSandboxName(session.claudeSessionId));
	} catch (error) {
		const detail = errorDetail(error);
		// Only a definite not-found means the sandbox is gone; any other lookup
		// failure (timeout, auth, rate limit) could be hiding a live machine —
		// report it as such so the caller doesn't drop the resume pointer
		// (codex review finding, gpt-5.5 xhigh).
		return isNotFound(error)
			? { disposition: "expired", detail }
			: { disposition: "unreachable", detail };
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
