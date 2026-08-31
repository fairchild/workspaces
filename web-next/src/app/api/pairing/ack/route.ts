/*
 * The pairing handshake endpoint. POST — called by a mobile client right
 * after it validates a scanned pairing code — proves possession of the local
 * sign-in token and records the acknowledgment under WEB_NEXT_DATA_DIR;
 * GET returns the latest acknowledgment so the desktop app's pairing window
 * can flip its QR into a confirmation. Self-authenticating (token in the
 * POST body, never the URL), so middleware treats it as public.
 */
import { localSignInTokenMatches } from "@/lib/auth/local-token";
import { localModeEnabled } from "@/lib/auth/config";
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

export async function GET(): Promise<Response> {
	if (!localModeEnabled()) {
		return Response.json({ error: "pairing is a local-mode feature" }, { status: 404 });
	}
	return Response.json(await readPairingAck());
}
