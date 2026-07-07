import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import { type DatabaseHandle, openDatabase } from "../db/client";
import {
	issueTerminalTicket,
	redeemTerminalTicket,
	TERMINAL_TICKET_TTL_MS,
} from "./tickets";

let open: DatabaseHandle | undefined;
let dir: string | undefined;

function freshDb(): DatabaseHandle {
	dir = mkdtempSync(join(tmpdir(), "web-next-tickets-"));
	open = openDatabase(`file:${join(dir, "test.db")}`);
	return open;
}

afterEach(async () => {
	await open?.db.destroy();
	open = undefined;
	if (dir) rmSync(dir, { recursive: true, force: true });
	dir = undefined;
});

const MINT = {
	login: "fairchild",
	sessionId: "session-1",
	mode: "ttyd" as const,
	sandboxName: "ai-sdk-harness-session-session-1",
};

describe("terminal tickets", () => {
	test("mint → redeem roundtrip returns the bound record exactly once", async () => {
		const db = freshDb();
		const { ticket, expiresAt } = await issueTerminalTicket(db, MINT);
		expect(new Date(expiresAt).getTime()).toBeGreaterThan(Date.now());

		const first = await redeemTerminalTicket(db, ticket, {
			login: "fairchild",
			sessionId: "session-1",
		});
		expect(first).toEqual({
			ok: true,
			record: {
				login: "fairchild",
				sessionId: "session-1",
				mode: "ttyd",
				sandboxName: MINT.sandboxName,
			},
		});

		// Replay: the same ticket never redeems twice.
		const replay = await redeemTerminalTicket(db, ticket, {
			login: "fairchild",
			sessionId: "session-1",
		});
		expect(replay).toEqual({ ok: false, reason: "redeemed" });
	});

	test("a tampered or unknown ticket is invalid", async () => {
		const db = freshDb();
		const { ticket } = await issueTerminalTicket(db, MINT);
		const tampered = ticket.slice(0, -2) + (ticket.endsWith("AA") ? "BB" : "AA");
		expect(
			await redeemTerminalTicket(db, tampered, {
				login: "fairchild",
				sessionId: "session-1",
			}),
		).toEqual({ ok: false, reason: "invalid" });
	});

	test("a ticket is bound to the login and session it was minted for", async () => {
		const db = freshDb();
		const { ticket } = await issueTerminalTicket(db, MINT);
		expect(
			await redeemTerminalTicket(db, ticket, {
				login: "mallory",
				sessionId: "session-1",
			}),
		).toEqual({ ok: false, reason: "wrong-user" });
		expect(
			await redeemTerminalTicket(db, ticket, {
				login: "fairchild",
				sessionId: "session-2",
			}),
		).toEqual({ ok: false, reason: "wrong-session" });
		// The failed attempts spent nothing: the rightful redeem still works.
		const rightful = await redeemTerminalTicket(db, ticket, {
			login: "fairchild",
			sessionId: "session-1",
		});
		expect(rightful.ok).toBe(true);
	});

	test("a ticket expires after its TTL", async () => {
		const db = freshDb();
		const minted = new Date("2026-07-07T00:00:00.000Z");
		const { ticket } = await issueTerminalTicket(db, MINT, minted);
		const justAfter = new Date(minted.getTime() + TERMINAL_TICKET_TTL_MS + 1);
		expect(
			await redeemTerminalTicket(
				db,
				ticket,
				{ login: "fairchild", sessionId: "session-1" },
				justAfter,
			),
		).toEqual({ ok: false, reason: "expired" });
	});

	test("issuing prunes rows that have already expired", async () => {
		const db = freshDb();
		const past = new Date(Date.now() - 2 * TERMINAL_TICKET_TTL_MS);
		await issueTerminalTicket(db, MINT, past);
		await issueTerminalTicket(db, MINT);
		const rows = await db.db
			.selectFrom("terminal_tickets")
			.selectAll()
			.execute();
		expect(rows).toHaveLength(1);
	});
});
