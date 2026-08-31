/*
 * The pairing handshake endpoint. Middleware treats it as public because both
 * verbs authenticate themselves with the minted local token — never with
 * network position, which `tailscale serve` cannot attest (a peer can send any
 * Host it likes; verified). POST — the mobile client's handshake right after it
 * validates a scanned code — carries the token in its body and records the
 * acknowledgment under WEB_NEXT_DATA_DIR. GET returns the latest acknowledgment
 * to a Bearer-authenticated caller: the desktop pairing window polling to flip
 * its QR, and the paired client checking whether its token still works.
 */
import { localSignInTokenMatches } from "@/lib/auth/local-token";
import { localModeEnabled } from "@/lib/auth/config";
import { readPairingAck, writePairingAck } from "@/lib/pairing/ack-store";

export const runtime = "nodejs";

/** `Authorization: Bearer <minted token>`, compared in constant time. */
function bearerTokenMatches(header: string | null): boolean {
	const [scheme, value] = (header ?? "").split(" ");
	if (scheme?.toLowerCase() !== "bearer" || !value) return false;
	return localSignInTokenMatches(value);
}

export async function POST(request: Request): Promise<Response> {
	if (!localModeEnabled()) {
		return Response.json({ error: "pairing is a local-mode feature" }, { status: 404 });
	}
	let token: unknown;
	try {
		({ token } = await request.json());
	} catch {
		return Response.json({ error: "expected a JSON body" }, { status: 400 });
	}
	if (typeof token !== "string" || !localSignInTokenMatches(token)) {
		return Response.json({ error: "invalid pairing token" }, { status: 401 });
	}
	await writePairingAck(request.headers.get("user-agent"), "handshake");
	return Response.json({ ok: true });
}

export async function GET(request: Request): Promise<Response> {
	if (!localModeEnabled()) {
		return Response.json({ error: "pairing is a local-mode feature" }, { status: 404 });
	}
	// The token is the gate here as everywhere else
	// (docs/decisions/mobile-tailnet-design.md). A loopback-looking Host is not
	// proof of a local caller: Serve forwards whatever Host the peer sent, so
	// `Host: localhost` from across the tailnet would otherwise read this.
	if (!bearerTokenMatches(request.headers.get("authorization"))) {
		return Response.json({ error: "invalid pairing token" }, { status: 401 });
	}
	return Response.json(await readPairingAck());
}
