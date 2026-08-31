/*
 * The pairing handshake endpoint. POST — called by a mobile client right
 * after it validates a scanned pairing code — proves possession of the local
 * sign-in token and records the acknowledgment under WEB_NEXT_DATA_DIR;
 * GET returns the latest acknowledgment so the desktop app's pairing window
 * can flip its QR into a confirmation. Self-authenticating (token in the
 * POST body, never the URL), so middleware treats it as public.
 */
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { localSignInTokenMatches } from "@/lib/auth/local-token";
import { localModeEnabled } from "@/lib/auth/config";
import { resolveWebNextDataDir } from "@/lib/local-data-dir";

export const runtime = "nodejs";

const ACK_FILENAME = "pairing-ack.json";
const USER_AGENT_MAX = 120;

function ackFilePath(): string {
	return path.join(resolveWebNextDataDir(process.env), ACK_FILENAME);
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
	const ack = {
		pairedAt: new Date().toISOString(),
		userAgent: (request.headers.get("user-agent") ?? "").slice(0, USER_AGENT_MAX),
	};
	await writeFile(ackFilePath(), `${JSON.stringify(ack)}\n`, { mode: 0o600 });
	return Response.json({ ok: true });
}

export async function GET(): Promise<Response> {
	if (!localModeEnabled()) {
		return Response.json({ error: "pairing is a local-mode feature" }, { status: 404 });
	}
	try {
		const raw = await readFile(ackFilePath(), "utf8");
		const parsed = JSON.parse(raw) as { pairedAt?: string; userAgent?: string };
		return Response.json({
			pairedAt: typeof parsed.pairedAt === "string" ? parsed.pairedAt : null,
			userAgent: typeof parsed.userAgent === "string" ? parsed.userAgent : "",
		});
	} catch {
		return Response.json({ pairedAt: null, userAgent: "" });
	}
}
