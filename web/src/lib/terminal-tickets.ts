/**
 * Single-use, short-TTL terminal access tickets (`terminal_access_tickets`): issued
 * per request and redeemed exactly once, scoped to a user + session, so a client can
 * authorize a ttyd connection without carrying a long-lived credential. Queries run
 * as raw libsql (`getTurso`); the table's DDL lives in the baseline migration.
 */

import crypto from "node:crypto";
import { getTurso } from "./db";
import { ensureSchema } from "./schema";

export const TERMINAL_TICKET_TTL_MS = 30_000;

export interface IssuedTerminalTicket {
	ticket: string;
	expiresAt: string;
}

export interface TerminalTicketRecord {
	userId: string;
	repo: string;
	sessionId: string;
	computeInstanceId: string;
	computeBackend: string;
	expiresAt: string;
	redeemedAt: string | null;
}

export type ConsumeTerminalTicketResult =
	| { ok: true; ticket: TerminalTicketRecord }
	| {
			ok: false;
			reason: "invalid" | "wrong-user" | "expired" | "redeemed";
	  };

function ticketHash(ticket: string): string {
	return crypto.createHash("sha256").update(ticket, "utf8").digest("hex");
}

async function pruneExpiredTickets(nowIso: string): Promise<void> {
	await getTurso().execute({
		sql: "DELETE FROM terminal_access_tickets WHERE expires_at <= ?",
		args: [nowIso],
	});
}

export async function issueTerminalTicket(
	params: {
		userId: string;
		repo: string;
		sessionId: string;
		computeInstanceId: string;
		computeBackend: string;
	},
	now = new Date(),
): Promise<IssuedTerminalTicket> {
	await ensureSchema();

	const ticket = crypto.randomBytes(32).toString("base64url");
	const createdAt = now.toISOString();
	const expiresAt = new Date(
		now.getTime() + TERMINAL_TICKET_TTL_MS,
	).toISOString();
	await pruneExpiredTickets(createdAt);
	await getTurso().execute({
		sql: `INSERT INTO terminal_access_tickets (
			ticket_hash,
			user_id,
			repo,
			session_id,
			compute_instance_id,
			compute_backend,
			created_at,
			expires_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		args: [
			ticketHash(ticket),
			params.userId,
			params.repo,
			params.sessionId,
			params.computeInstanceId,
			params.computeBackend,
			createdAt,
			expiresAt,
		],
	});

	return { ticket, expiresAt };
}

export async function consumeTerminalTicket(
	ticket: string,
	userId: string,
	now = new Date(),
): Promise<ConsumeTerminalTicketResult> {
	await ensureSchema();

	const nowIso = now.toISOString();
	const hash = ticketHash(ticket);
	const row = await getTurso().execute({
		sql: `SELECT
			user_id,
			repo,
			session_id,
			compute_instance_id,
			compute_backend,
			expires_at,
			redeemed_at
		FROM terminal_access_tickets
		WHERE ticket_hash = ?
		LIMIT 1`,
		args: [hash],
	});
	const record = row.rows[0];
	if (!record) return { ok: false, reason: "invalid" };

	if (String(record.user_id) !== userId) {
		return { ok: false, reason: "wrong-user" };
	}
	if (record.redeemed_at !== null) {
		return { ok: false, reason: "redeemed" };
	}
	if (String(record.expires_at) <= nowIso) {
		return { ok: false, reason: "expired" };
	}

	const updated = await getTurso().execute({
		sql: `UPDATE terminal_access_tickets
			SET redeemed_at = ?
			WHERE ticket_hash = ?
				AND user_id = ?
				AND redeemed_at IS NULL
				AND expires_at > ?`,
		args: [nowIso, hash, userId, nowIso],
	});
	if (updated.rowsAffected !== 1) {
		return { ok: false, reason: "redeemed" };
	}

	return {
		ok: true,
		ticket: {
			userId: String(record.user_id),
			repo: String(record.repo),
			sessionId: String(record.session_id),
			computeInstanceId: String(record.compute_instance_id),
			computeBackend: String(record.compute_backend),
			expiresAt: String(record.expires_at),
			redeemedAt: nowIso,
		},
	};
}
