/*
 * The pairing handshake endpoint, public to middleware but gated per verb.
 * POST — called by a mobile client right after it validates a scanned pairing
 * code — proves possession of the local sign-in token (in the body, never the
 * URL) and records the acknowledgment under WEB_NEXT_DATA_DIR; it must work
 * from the phone, so it accepts any allowlisted origin. GET returns the latest
 * acknowledgment for the desktop pairing window to flip its QR, and that
 * caller is always loopback — so GET refuses proxied callers rather than
 * telling any tailnet peer who paired last.
 */
import { localSignInTokenMatches } from "@/lib/auth/local-token";
import { isLoopbackHostHeader, localModeEnabled } from "@/lib/auth/config";
import { readPairingAck, writePairingAck } from "@/lib/pairing/ack-store";

export const runtime = "nodejs";

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
	// The desktop pairing window polls this over loopback; nothing else has
	// standing to read it. Off loopback the token is the gate everywhere
	// (docs/decisions/mobile-tailnet-design.md), and this response carries no
	// token — so it refuses rather than leaking who paired last.
	if (!isLoopbackHostHeader(request.headers.get("host"))) {
		return Response.json({ error: "pairing status is loopback-only" }, { status: 403 });
	}
	return Response.json(await readPairingAck());
}
