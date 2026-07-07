/*
 * The terminal transport seam (#752): one interface the drawer speaks, two
 * implementations behind it — the real ttyd WebSocket and the deterministic
 * mock PTY (AUTH_BYPASS e2e/perf). requestTerminalAccess runs the ticket
 * exchange: mint and redeem are both authenticated POSTs with the ticket in
 * the body, so no token ever rides in a URL the browser records.
 */

export interface TerminalTransportHandlers {
	/** Bytes/text from the PTY, ready to write to the terminal. */
	onData(text: string): void;
	/** The transport ended (socket closed, sandbox gone). */
	onClose(reason: string): void;
}

export interface TerminalConnection {
	/** Keystrokes from the terminal to the PTY. */
	send(data: string): void;
	resize(cols: number, rows: number): void;
	close(): void;
}

export type TerminalAccess =
	| { kind: "mock" }
	| { kind: "ttyd"; wsUrl: string }
	| { kind: "no-sandbox"; reason: string }
	| { kind: "denied"; message: string };

interface MintResponse {
	state?: string;
	mode?: string;
	ticket?: string;
	reason?: string;
	error?: string;
}

interface RedeemResponse {
	mode?: string;
	wsUrl?: string;
	error?: string;
}

async function readJson<T>(response: Response): Promise<T> {
	return response.json().catch(() => ({}) as T);
}

export async function requestTerminalAccess(
	sessionId: string,
): Promise<TerminalAccess> {
	const mint = await fetch(`/api/sessions/${sessionId}/terminal`, {
		method: "POST",
	});
	const minted = await readJson<MintResponse>(mint);
	if (!mint.ok) {
		return {
			kind: "denied",
			message: minted.error ?? `terminal access denied (HTTP ${mint.status})`,
		};
	}
	if (minted.state === "no-sandbox") {
		return { kind: "no-sandbox", reason: minted.reason ?? "no live sandbox" };
	}
	if (!minted.ticket) {
		return { kind: "denied", message: "terminal mint returned no ticket" };
	}

	const redeem = await fetch(`/api/sessions/${sessionId}/terminal/redeem`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ ticket: minted.ticket }),
	});
	const redeemed = await readJson<RedeemResponse>(redeem);
	if (!redeem.ok) {
		return {
			kind: "denied",
			message: redeemed.error ?? `ticket redemption failed (HTTP ${redeem.status})`,
		};
	}
	if (redeemed.mode === "mock") return { kind: "mock" };
	if (redeemed.mode === "ttyd" && redeemed.wsUrl) {
		return { kind: "ttyd", wsUrl: redeemed.wsUrl };
	}
	return { kind: "denied", message: "ticket redemption returned no transport" };
}
