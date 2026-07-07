/*
 * Single-use, short-TTL terminal access tickets (#752) — the authenticated
 * exchange in front of every terminal attach, ported from web/'s
 * terminal-tickets. Mint issues 32 random bytes and stores only their SHA-256
 * (a stolen table row is not a ticket; a lookup by digest also blunts timing
 * probes on the comparison); redeem consumes exactly once via an atomic
 * UPDATE guard and checks the login + session binding and the expiry clock.
 */
import crypto from "node:crypto";
import type { DatabaseHandle } from "../db/client";
import { ensureSchema } from "../db/schema";

export const TERMINAL_TICKET_TTL_MS = 30_000;

/** Transport the mint resolved: a live sandbox's ttyd, or the bypass mock. */
export type TerminalMode = "ttyd" | "mock";

export interface IssuedTerminalTicket {
	ticket: string;
	expiresAt: string;
}

export interface TerminalTicketRecord {
	login: string;
	sessionId: string;
	mode: TerminalMode;
	/** Sandbox the ticket is pinned to (redeem re-verifies it); null for mock. */
	sandboxName: string | null;
}

export type RedeemTicketResult =
	| { ok: true; record: TerminalTicketRecord }
	| {
			ok: false;
			reason: "invalid" | "wrong-user" | "wrong-session" | "expired" | "redeemed";
	  };

function ticketHash(ticket: string): string {
	return crypto.createHash("sha256").update(ticket, "utf8").digest("hex");
}

export async function issueTerminalTicket(
	handle: DatabaseHandle,
	params: {
		login: string;
		sessionId: string;
		mode: TerminalMode;
		sandboxName?: string | null;
	},
	now = new Date(),
): Promise<IssuedTerminalTicket> {
	await ensureSchema(handle);
	const ticket = crypto.randomBytes(32).toString("base64url");
	const createdAt = now.toISOString();
	const expiresAt = new Date(now.getTime() + TERMINAL_TICKET_TTL_MS).toISOString();
	// Opportunistic hygiene: expired rows are dead weight, never redeemable.
	await handle.db
		.deleteFrom("terminal_tickets")
		.where("expires_at", "<=", createdAt)
		.execute();
	await handle.db
		.insertInto("terminal_tickets")
		.values({
			ticket_hash: ticketHash(ticket),
			login: params.login,
			session_id: params.sessionId,
			mode: params.mode,
			sandbox_name: params.sandboxName ?? null,
			created_at: createdAt,
			expires_at: expiresAt,
			redeemed_at: null,
		})
		.execute();
	return { ticket, expiresAt };
}

export async function redeemTerminalTicket(
	handle: DatabaseHandle,
	ticket: string,
	params: { login: string; sessionId: string },
	now = new Date(),
): Promise<RedeemTicketResult> {
	await ensureSchema(handle);
	const nowIso = now.toISOString();
	const hash = ticketHash(ticket);
	const row = await handle.db
		.selectFrom("terminal_tickets")
		.selectAll()
		.where("ticket_hash", "=", hash)
		.executeTakeFirst();
	if (!row) return { ok: false, reason: "invalid" };
	if (row.login !== params.login) return { ok: false, reason: "wrong-user" };
	if (row.session_id !== params.sessionId)
		return { ok: false, reason: "wrong-session" };
	if (row.redeemed_at !== null) return { ok: false, reason: "redeemed" };
	if (row.expires_at <= nowIso) return { ok: false, reason: "expired" };

	// Exactly-once: the guard re-checks under the write, so two concurrent
	// redeems of one ticket produce one winner and one "redeemed".
	const updated = await handle.db
		.updateTable("terminal_tickets")
		.set({ redeemed_at: nowIso })
		.where("ticket_hash", "=", hash)
		.where("login", "=", params.login)
		.where("redeemed_at", "is", null)
		.where("expires_at", ">", nowIso)
		.executeTakeFirst();
	if (Number(updated.numUpdatedRows ?? 0) !== 1) {
		return { ok: false, reason: "redeemed" };
	}
	return {
		ok: true,
		record: {
			login: row.login,
			sessionId: row.session_id,
			mode: row.mode as TerminalMode,
			sandboxName: row.sandbox_name,
		},
	};
}
